function [selectedRelease, selectedRouting, scores, trainingState] = selectReleaseWithDigitalModel(releaseCandidates, baseRouting, cycleTimeTable, sysState, config)
%SELECTRELEASEWITHDIGITALMODEL Score plans through dm_run and persist GA state.
%
% When UsePersistentGaTraining is true, repeated Digital Model runs continue
% an evolutionary search over a 19-value genome:
%   [PT1..PT5 release quantities, 14 routing weights]

selectedRelease = releaseCandidates{1};
selectedRouting = baseRouting;

if localUseTrainedPolicyOnly(config)
    trainingState = localLoadPolicyTrainingState(config);
    [selectedRelease, selectedRouting, scores, plan] = localSelectTrainedPolicy( ...
        releaseCandidates{1}, cycleTimeTable, config, trainingState);
    if localScoreTrainedPolicy(config)
        [selectedRelease, selectedRouting, scores] = localScoreSingleTrainedPolicyPlan( ...
            plan, cycleTimeTable, sysState, config);
    end
    return
end

trainingState = localLoadTrainingState(config);

[plans, trainingState] = localBuildPlans(releaseCandidates, baseRouting, config, trainingState);
nPlans = numel(plans);
scores = localScoreTable(nPlans);
for i = 1:numel(plans)
    scores.ReleaseRows(i) = height(plans(i).ReleaseTable);
    scores.Source(i) = plans(i).Source;
end

if ~config.UseDigitalModelScoring
    mode = localCampaignMode(config);
    if (mode == "full" || mode == "final") && ~isempty(plans)
        selectedRelease = plans(1).ReleaseTable;
        selectedRouting = plans(1).RoutingTable;
    end
    scores.Status(:) = "digital model scoring disabled";
    return
end

if ~isfolder(config.DmDir)
    scores.Status(:) = "digital model folder not found";
    return
end

try
    dmRunDir = localPrepareDmRunDir(config);
    localInstallSysState(sysState, dmRunDir, config);
catch prepError
    scores.Status(:) = "digital model prep failed: " + string(prepError.message);
    return
end

useLiveRunner = isfield(config, 'UseLiveDigitalModelRunner') && config.UseLiveDigitalModelRunner;
if ~useLiveRunner && ~isfile(fullfile(dmRunDir, 'dm_run.p')) && ~isfile(fullfile(dmRunDir, 'dm_run.m'))
    scores.Status(:) = "dm_run not found in digital model run folder";
    return
end

originalDir = pwd;
cleanup = onCleanup(@() cd(originalDir));
cd(dmRunDir);
addpath(dmRunDir);

dashboardRunId = string(datestr(now, 'yyyymmdd_HHMMSS_FFF'));
for i = 1:numel(plans)
    try
        campaignInfo = localCampaignInfo(plans(i).ReleaseTable, config);
        campaignInfo.Candidate = i;
        campaignInfo.Source = plans(i).Source;
        campaignInfo.DashboardRunId = dashboardRunId;
        finishString = campaignInfo.FinishTimeString;

        scores.CampaignMode(i) = campaignInfo.CampaignMode;
        scores.HorizonHours(i) = campaignInfo.HorizonHours;
        scores.StartTime(i) = campaignInfo.StartTime;
        scores.FinishTime(i) = campaignInfo.FinishTime;
        scores.FinishTimeString(i) = finishString;

        fprintf(['Scoring DM candidate %d/%d: mode=%s, horizon=%.2f h, ', ...
            'replications=%d, finish=%s.\n'], i, numel(plans), ...
            campaignInfo.CampaignMode, campaignInfo.HorizonHours, ...
            config.DmReplications, finishString);

        if localUseWeeklyAggregateFullHorizon(campaignInfo, config)
            [dmResult, seeds, liveLog] = localRunWeeklyAggregateFullHorizon( ...
                plans(i), cycleTimeTable, config, campaignInfo, useLiveRunner); %#ok<ASGLU>
        else
            localWriteAndValidateDmInputs(plans(i).ReleaseTable, plans(i).RoutingTable, cycleTimeTable, dmRunDir);
            if localShouldConfigureDigitalModel(config)
                localConfigureDigitalModelInputs(dmRunDir);
            end
            [dmResult, seeds, liveLog] = localRunDigitalModelOnce(finishString, config, campaignInfo, useLiveRunner); %#ok<ASGLU>
        end

        scoreConfig = localScoreConfigForPlan(config, campaignInfo.CampaignTarget, ...
            plans(i).ReleaseTable);
        scores.Score(i) = cpms.extractDmScore(dmResult, scoreConfig);
        scores.SimulatedShifts(i) = localSimulatedShiftCount(dmResult, campaignInfo);
        scores.NormalizedScore(i) = scores.Score(i) / max(1, scores.SimulatedShifts(i));
        scores.Status(i) = "ok";
        campaignInfo.Score = scores.Score(i);
        campaignInfo.NormalizedScore = scores.NormalizedScore(i);
        campaignInfo.SimulatedShifts = scores.SimulatedShifts(i);
        localAppendDmProductionLog(dmResult, plans(i), i, scores.Score(i), ...
            scores.NormalizedScore(i), campaignInfo, liveLog, config);
        localPlotOfficialDmDashboardIfNeeded(dmResult, plans(i), i, ...
            scores.Score(i), scores.NormalizedScore(i), campaignInfo, config, useLiveRunner);
        fprintf('DM candidate %d/%d finished: score=%.3f, normalized=%.3f.\n', ...
            i, numel(plans), scores.Score(i), scores.NormalizedScore(i));
    catch dmError
        scores.Score(i) = -Inf;
        scores.NormalizedScore(i) = -Inf;
        scores.Status(i) = string(dmError.message);
        fprintf('DM candidate %d/%d failed: %s\n', i, numel(plans), dmError.message);
    end
end

localGuardCandidateScoreDiversity(plans, scores, config);

valid = find(isfinite(scores.Score));
if ~isempty(valid)
    [~, localIdx] = max(scores.Score(valid));
    bestIdx = valid(localIdx);
    selectedRelease = plans(bestIdx).ReleaseTable;
    selectedRouting = plans(bestIdx).RoutingTable;
end

localWriteSelectedPlanToDmWork(selectedRelease, selectedRouting, cycleTimeTable, config);

if config.UsePersistentGaTraining
    trainingState = localUpdateTrainingState(trainingState, plans, scores, config);
end
end

function [plans, trainingState] = localBuildPlans(releaseCandidates, baseRouting, config, trainingState)
if config.UsePersistentGaTraining
    baseGenome = localBaseGenome(releaseCandidates{1}, baseRouting, config);
    population = localNextPopulation(trainingState, baseGenome, config);
    n = min(config.NumReleaseCandidates, size(population, 1));
    plans = repmat(localGenomeToPlan(population(1, :), releaseCandidates{1}, config, "ga"), n, 1);
    for i = 1:n
        plans(i) = localGenomeToPlan(population(i, :), releaseCandidates{1}, config, "ga");
    end
    trainingState.PendingPopulation = population;
    return
end

n = numel(releaseCandidates);
plans = repmat(struct('ReleaseTable', releaseCandidates{1}, ...
    'RoutingTable', baseRouting, 'Genome', [], 'Source', "candidate"), n, 1);
for i = 1:n
    plans(i).ReleaseTable = releaseCandidates{i};
    plans(i).RoutingTable = baseRouting;
    plans(i).Genome = localBaseGenome(releaseCandidates{i}, baseRouting, config);
    plans(i).Source = "candidate";
end
end

function tf = localUseTrainedPolicyOnly(config)
tf = isfield(config, 'UseTrainedGaPolicyOnly') && ...
    ~isempty(config.UseTrainedGaPolicyOnly) && logical(config.UseTrainedGaPolicyOnly);
end

function tf = localScoreTrainedPolicy(config)
tf = isfield(config, 'ScoreTrainedGaPolicy') && ...
    ~isempty(config.ScoreTrainedGaPolicy) && logical(config.ScoreTrainedGaPolicy) && ...
    isfield(config, 'UseDigitalModelScoring') && logical(config.UseDigitalModelScoring);
end

function scores = localScoreTable(nPlans)
scores = table((1:nPlans)', zeros(nPlans, 1), ...
    nan(nPlans, 1), nan(nPlans, 1), nan(nPlans, 1), ...
    repmat("not run", nPlans, 1), repmat("baseline", nPlans, 1), ...
    repmat("", nPlans, 1), nan(nPlans, 1), NaT(nPlans, 1), NaT(nPlans, 1), ...
    repmat("", nPlans, 1), ...
    'VariableNames', {'Candidate', 'ReleaseRows', 'Score', 'NormalizedScore', ...
    'SimulatedShifts', 'Status', 'Source', 'CampaignMode', 'HorizonHours', ...
    'StartTime', 'FinishTime', 'FinishTimeString'});
end

function [selectedRelease, selectedRouting, scores, plan] = localSelectTrainedPolicy( ...
    templateRelease, cycleTimeTable, config, trainingState)
if ~isfield(trainingState, 'BestGenome') || isempty(trainingState.BestGenome)
    error('cpms:MissingTrainedPolicy', ...
        ['No saved best GA genome was found. Run weekly DM training first, ', ...
        'or set TrainedPolicyStateFile to a valid cpms_ga_training_<mode>.mat file.']);
end

plan = localGenomeToPlan(trainingState.BestGenome, templateRelease, config, "trained-best");
selectedRelease = plan.ReleaseTable;
selectedRouting = plan.RoutingTable;
localWriteSelectedPlanToDmWork(selectedRelease, selectedRouting, cycleTimeTable, config);

campaignInfo = localCampaignInfo(selectedRelease, config);
scores = localScoreTable(1);
scores.ReleaseRows(1) = height(selectedRelease);
scores.Score(1) = localStructValue(trainingState, 'BestScore', NaN);
scores.NormalizedScore(1) = localStructValue(trainingState, 'BestNormalizedScore', NaN);
scores.SimulatedShifts(1) = campaignInfo.SimulatedShifts;
scores.Status(1) = "trained best policy applied without DM scoring";
scores.Source(1) = plan.Source;
scores.CampaignMode(1) = campaignInfo.CampaignMode;
scores.HorizonHours(1) = campaignInfo.HorizonHours;
scores.StartTime(1) = campaignInfo.StartTime;
scores.FinishTime(1) = campaignInfo.FinishTime;
scores.FinishTimeString(1) = campaignInfo.FinishTimeString;
end

function [selectedRelease, selectedRouting, scores] = localScoreSingleTrainedPolicyPlan( ...
    plan, cycleTimeTable, sysState, config)
selectedRelease = plan.ReleaseTable;
selectedRouting = plan.RoutingTable;
scores = localScoreTable(1);
scores.ReleaseRows(1) = height(plan.ReleaseTable);
scores.Source(1) = plan.Source;

if ~isfolder(config.DmDir)
    scores.Status(1) = "digital model folder not found";
    return
end

try
    dmRunDir = localPrepareDmRunDir(config);
    localInstallSysState(sysState, dmRunDir, config);
catch prepError
    scores.Status(1) = "digital model prep failed: " + string(prepError.message);
    return
end

useLiveRunner = isfield(config, 'UseLiveDigitalModelRunner') && config.UseLiveDigitalModelRunner;
if ~useLiveRunner && ~isfile(fullfile(dmRunDir, 'dm_run.p')) && ~isfile(fullfile(dmRunDir, 'dm_run.m'))
    scores.Status(1) = "dm_run not found in digital model run folder";
    return
end

originalDir = pwd;
cleanup = onCleanup(@() cd(originalDir));
cd(dmRunDir);
addpath(dmRunDir);

try
    campaignInfo = localCampaignInfo(plan.ReleaseTable, config);
    campaignInfo.Candidate = 1;
    campaignInfo.Source = plan.Source;
    campaignInfo.DashboardRunId = string(datestr(now, 'yyyymmdd_HHMMSS_FFF'));
    finishString = campaignInfo.FinishTimeString;

    scores.CampaignMode(1) = campaignInfo.CampaignMode;
    scores.HorizonHours(1) = campaignInfo.HorizonHours;
    scores.StartTime(1) = campaignInfo.StartTime;
    scores.FinishTime(1) = campaignInfo.FinishTime;
    scores.FinishTimeString(1) = finishString;

    fprintf(['Scoring trained best policy only: mode=%s, horizon=%.2f h, ', ...
        'replications=%d, finish=%s.\n'], campaignInfo.CampaignMode, ...
        campaignInfo.HorizonHours, config.DmReplications, finishString);

    if localUseWeeklyAggregateFullHorizon(campaignInfo, config)
        [dmResult, seeds, liveLog] = localRunWeeklyAggregateFullHorizon( ...
            plan, cycleTimeTable, config, campaignInfo, useLiveRunner); %#ok<ASGLU>
    else
        localWriteAndValidateDmInputs(plan.ReleaseTable, plan.RoutingTable, cycleTimeTable, dmRunDir);
        if localShouldConfigureDigitalModel(config)
            localConfigureDigitalModelInputs(dmRunDir);
        end
        [dmResult, seeds, liveLog] = localRunDigitalModelOnce( ...
            finishString, config, campaignInfo, useLiveRunner); %#ok<ASGLU>
    end

    scoreConfig = localScoreConfigForPlan(config, campaignInfo.CampaignTarget, ...
        plan.ReleaseTable);
    scores.Score(1) = cpms.extractDmScore(dmResult, scoreConfig);
    scores.SimulatedShifts(1) = localSimulatedShiftCount(dmResult, campaignInfo);
    scores.NormalizedScore(1) = scores.Score(1) / max(1, scores.SimulatedShifts(1));
    scores.Status(1) = "ok";
    campaignInfo.Score = scores.Score(1);
    campaignInfo.NormalizedScore = scores.NormalizedScore(1);
    campaignInfo.SimulatedShifts = scores.SimulatedShifts(1);
    localAppendDmProductionLog(dmResult, plan, 1, scores.Score(1), ...
        scores.NormalizedScore(1), campaignInfo, liveLog, config);
    localPlotOfficialDmDashboardIfNeeded(dmResult, plan, 1, ...
        scores.Score(1), scores.NormalizedScore(1), campaignInfo, config, useLiveRunner);
    fprintf('Trained best policy DM rehearsal finished: score=%.3f, normalized=%.3f.\n', ...
        scores.Score(1), scores.NormalizedScore(1));
catch dmError
    scores.Score(1) = -Inf;
    scores.NormalizedScore(1) = -Inf;
    scores.Status(1) = string(dmError.message);
    fprintf('Trained best policy DM rehearsal failed: %s\n', dmError.message);
end

localWriteSelectedPlanToDmWork(selectedRelease, selectedRouting, cycleTimeTable, config);
end

function trainingState = localLoadPolicyTrainingState(config)
policyConfig = config;
policyConfig.TrainingStateFile = localPolicyTrainingStateFile(config);
trainingState = localLoadTrainingState(policyConfig);
end

function path = localPolicyTrainingStateFile(config)
if isfield(config, 'TrainedPolicyStateFile') && ...
        strlength(string(config.TrainedPolicyStateFile)) > 0
    path = char(config.TrainedPolicyStateFile);
    return
end
mode = "weekly";
if isfield(config, 'TrainedPolicyMode') && strlength(string(config.TrainedPolicyMode)) > 0
    mode = lower(string(config.TrainedPolicyMode));
end
if mode == "final"
    mode = "full";
end
path = fullfile(config.ProjectRoot, 'DSS_Output', "cpms_ga_training_" + mode + ".mat");
path = char(path);
end

function tf = localShouldConfigureDigitalModel(config)
tf = ~isfield(config, 'ConfigureDigitalModelBeforeRun') || config.ConfigureDigitalModelBeforeRun;
end

function localConfigureDigitalModelInputs(runDir)
if nargin < 1 || strlength(string(runDir)) == 0
    runDir = pwd;
end
targetRunDir = char(runDir);
if ~isfolder(targetRunDir)
    error('cpms:MissingDmRunDir', ...
        'Digital Model run folder does not exist: %s', targetRunDir);
end
if exist('dm_config', 'file') == 0
    error('cpms:MissingDmConfig', ...
        'dm_config was not found on the MATLAB path in the Digital Model run folder.');
end

% dm_config is supplied as p-code and may behave like a script that clears
% the caller workspace or changes pwd. Persist the intended run folder so the
% live runner always loads the just-written candidate workbooks.
tmpFile = fullfile(tempdir, 'cpms_dm_config_run_dir.mat');
save(tmpFile, 'targetRunDir');
cd(targetRunDir);
fprintf('Configuring Digital Model input tables with dm_config.\n');
try
    dm_config;
catch configError
    localRestoreDmRunDirAfterConfig();
    rethrow(configError);
end
localRestoreDmRunDirAfterConfig();
fprintf('Digital Model input configuration complete.\n');
end

function localRestoreDmRunDirAfterConfig()
tmpFile = fullfile(tempdir, 'cpms_dm_config_run_dir.mat');
if ~isfile(tmpFile)
    return
end
S = load(tmpFile, 'targetRunDir');
try
    delete(tmpFile);
catch
end
if isfield(S, 'targetRunDir') && isfolder(S.targetRunDir)
    cd(S.targetRunDir);
end
end

function localWriteSelectedPlanToDmWork(selectedRelease, selectedRouting, cycleTimeTable, config)
if ~isfield(config, 'UseDmWorkingCopy') || ~config.UseDmWorkingCopy || ...
        ~isfield(config, 'DmWorkDir') || ~isfolder(config.DmWorkDir)
    return
end
try
    localDeleteIfExists(fullfile(config.DmWorkDir, 'ReleaseTable.xlsx'));
    localDeleteIfExists(fullfile(config.DmWorkDir, 'RoutingTable.xlsx'));
    localDeleteIfExists(fullfile(config.DmWorkDir, 'CycleTimeTable.xlsx'));
    writetable(selectedRelease, fullfile(config.DmWorkDir, 'ReleaseTable.xlsx'));
    writetable(selectedRouting, fullfile(config.DmWorkDir, 'RoutingTable.xlsx'));
    writetable(cycleTimeTable, fullfile(config.DmWorkDir, 'CycleTimeTable.xlsx'));
catch syncError
    warning('cpms:DmWorkSelectedPlanSyncFailed', ...
        'Could not synchronize selected plan back to DM_Work: %s', syncError.message);
end
end

function localPlotOfficialDmDashboardIfNeeded(dmResult, plan, candidateIndex, score, normalizedScore, campaignInfo, config, useLiveRunner)
if useLiveRunner
    return
end
if ~isfield(config, 'EnableLiveDashboard') || ~logical(config.EnableLiveDashboard)
    return
end
try
    cpms.plotDigitalModelDashboard(dmResult, plan, candidateIndex, score, ...
        normalizedScore, campaignInfo, config);
catch dashboardError
    warning('cpms:OfficialDmDashboardFailed', ...
        'Could not plot official DM dashboard: %s', dashboardError.message);
end
end

function scoreConfig = localScoreConfigForPlan(config, campaignTarget, releaseTable)
scoreConfig = config;
scoreConfig.ScoreTargetByPart = campaignTarget;
[plannedByPart, plannedTotal] = localReleaseTotals(releaseTable);
scoreConfig.ScorePlannedReleaseByPart = plannedByPart;
scoreConfig.ScorePlannedReleaseTotal = plannedTotal;
end

function localPlotWeeklyOfficialDmDashboardIfNeeded(weekResult, releaseWindow, plan, weekIndex, weekInfo, config, useLiveRunner)
if useLiveRunner
    return
end
if ~isfield(config, 'EnableLiveDashboard') || ~logical(config.EnableLiveDashboard)
    return
end

weekPlan = plan;
weekPlan.ReleaseTable = releaseWindow;
scoreConfig = localScoreConfigForPlan(config, weekInfo.CampaignTarget, releaseWindow);
weekScore = cpms.extractDmScore(weekResult, scoreConfig);
weekShifts = localSimulatedShiftCount(weekResult, weekInfo);
weekNormalizedScore = weekScore / max(1, weekShifts);
plotInfo = weekInfo;
plotInfo.CampaignMode = "full-week-" + string(weekIndex);

try
    cpms.plotDigitalModelDashboard(weekResult, weekPlan, ...
        localStructValue(weekInfo, 'Candidate', 1), weekScore, ...
        weekNormalizedScore, plotInfo, config);
catch dashboardError
    warning('cpms:OfficialDmWeeklyDashboardFailed', ...
        'Could not plot official weekly DM dashboard: %s', dashboardError.message);
end
end

function localGuardCandidateScoreDiversity(plans, scores, config)
ok = scores.Status == "ok" & isfinite(scores.NormalizedScore);
if sum(ok) < 2
    return
end

values = scores.NormalizedScore(ok);
tolerance = 1e-9;
if isfield(config, 'CollapsedScoreTolerance') && ~isempty(config.CollapsedScoreTolerance)
    tolerance = max(0, double(config.CollapsedScoreTolerance(1)));
end
if max(abs(values - values(1))) > tolerance * max(1, abs(values(1)))
    return
end

okIdx = find(ok);
releaseSignatures = strings(numel(okIdx), 1);
routingSignatures = strings(numel(okIdx), 1);
for i = 1:numel(okIdx)
    [releaseSignatures(i), routingSignatures(i)] = localPlanSignatures(plans(okIdx(i)));
end

releaseDiffers = numel(unique(releaseSignatures)) > 1;
routingDiffers = numel(unique(routingSignatures)) > 1;
if releaseDiffers || routingDiffers
    if routingDiffers
        message = ['All ok Digital Model candidates received the same normalized score, ', ...
            'but their routing plans differ. This usually means the DM did ', ...
            'not reload candidate Excel inputs. This generation is not valid GA ', ...
            'evidence and should not update the saved training state.'];
    else
        message = ['All ok Digital Model candidates received the same normalized score, ', ...
            'but their release plans differ. This can be legitimate when every ', ...
            'release plan is above the same capacity bottleneck, but it means this ', ...
            'run did not distinguish release pressure.'];
    end
    failHard = ~isfield(config, 'FailOnCollapsedCandidateScores') || ...
        isempty(config.FailOnCollapsedCandidateScores) || ...
        logical(config.FailOnCollapsedCandidateScores(1));
    if ~routingDiffers
        failHard = isfield(config, 'FailOnCollapsedReleaseOnlyScores') && ...
            ~isempty(config.FailOnCollapsedReleaseOnlyScores) && ...
            logical(config.FailOnCollapsedReleaseOnlyScores(1));
    end
    if failHard
        error('cpms:CollapsedCandidateScores', '%s', message);
    else
        warning('cpms:CollapsedCandidateScores', '%s', message);
    end
end
end

function [releaseSignature, routingSignature] = localPlanSignatures(plan)
releaseTotals = nan(1, 5);
if isstruct(plan) && isfield(plan, 'ReleaseTable') && istable(plan.ReleaseTable)
    [releaseTotals, ~] = localReleaseTotals(plan.ReleaseTable);
end

routing = [];
if isstruct(plan) && isfield(plan, 'RoutingTable') && istable(plan.RoutingTable) && ...
        width(plan.RoutingTable) > 1
    try
        routing = table2array(plan.RoutingTable(:, 2:end));
    catch
        routing = [];
    end
end

releaseValues = releaseTotals(:);
releaseValues(~isfinite(releaseValues)) = -999999;
releaseSignature = string(sprintf('%.3f,', releaseValues));

routingValues = routing(:);
routingValues(~isfinite(routingValues)) = -999999;
routingSignature = string(sprintf('%.3f,', routingValues));
end

function localWriteAndValidateDmInputs(releaseTable, routingTable, cycleTimeTable, dmRunDir)
localDeleteIfExists(fullfile(dmRunDir, 'ReleaseTable.xlsx'));
localDeleteIfExists(fullfile(dmRunDir, 'RoutingTable.xlsx'));
localDeleteIfExists(fullfile(dmRunDir, 'CycleTimeTable.xlsx'));
writetable(releaseTable, fullfile(dmRunDir, 'ReleaseTable.xlsx'));
writetable(routingTable, fullfile(dmRunDir, 'RoutingTable.xlsx'));
writetable(cycleTimeTable, fullfile(dmRunDir, 'CycleTimeTable.xlsx'));

validateReleaseTable(fullfile(dmRunDir, 'ReleaseTable.xlsx'));
validateRoutingTable(fullfile(dmRunDir, 'RoutingTable.xlsx'));
validateCycleTimeTable(fullfile(dmRunDir, 'CycleTimeTable.xlsx'));
end

function localDeleteIfExists(path)
if ~isfile(path)
    return
end
try
    delete(path);
catch deleteError
    error('cpms:DigitalModelWorkbookLocked', ...
        'Could not replace %s. Close Excel/Tecnomatix and retry. Details: %s', ...
        path, deleteError.message);
end
end

function [dmResult, seeds, liveLog] = localRunDigitalModelOnce(finishString, config, campaignInfo, useLiveRunner)
if useLiveRunner
    [dmResult, seeds, liveLog] = cpms.runDigitalModelLive(finishString, config, campaignInfo);
else
    localSeedOfficialDmRunner(config);
    [dmResult, seeds] = dm_run(finishString);
    liveLog = table();
end
end

function localSeedOfficialDmRunner(config)
if ~isfield(config, 'UseCommonRandomNumbers') || isempty(config.UseCommonRandomNumbers) || ...
        ~logical(config.UseCommonRandomNumbers(1))
    return
end

seed = 271828;
if isfield(config, 'DmRunMatlabRngSeed') && ~isempty(config.DmRunMatlabRngSeed)
    candidate = double(config.DmRunMatlabRngSeed(1));
    if isfinite(candidate)
        seed = round(candidate);
    end
end

rng(seed, 'twister');
end

function tf = localUseWeeklyAggregateFullHorizon(campaignInfo, config)
mode = lower(string(localStructValue(campaignInfo, 'CampaignMode', "")));
evalMode = "weeklyAggregate";
if isfield(config, 'FullHorizonEvaluationMode') && strlength(string(config.FullHorizonEvaluationMode)) > 0
    evalMode = lower(string(config.FullHorizonEvaluationMode));
end
tf = (mode == "full" || mode == "final") && evalMode == "weeklyaggregate";
end

function value = localStructValue(s, fieldName, fallback)
if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = s.(fieldName);
else
    value = fallback;
end
end

function value = localConfigNumber(config, fieldName, fallback)
value = fallback;
if isstruct(config) && isfield(config, fieldName) && ~isempty(config.(fieldName))
    candidate = double(config.(fieldName));
    candidate = candidate(1);
    if isfinite(candidate)
        value = candidate;
    end
end
end

function [dmResult, seeds, liveLog] = localRunWeeklyAggregateFullHorizon(plan, cycleTimeTable, config, campaignInfo, useLiveRunner)
windows = localWeeklyWindows(campaignInfo.StartTime, campaignInfo.FinishTime, config);
if isempty(windows)
    error('cpms:FullHorizonWindowsMissing', ...
        'No weekly windows could be generated for the full-horizon evaluation.');
end

baseStart = campaignInfo.StartTime;
baseAnchor = localWeekAnchor(baseStart);
fullShiftTimes = localProductionShiftTimes(campaignInfo.StartTime, campaignInfo.FinishTime, config);
weekResults = cell(height(windows), 1);
seedCells = cell(height(windows), 1);
liveLog = table();

runConfig = config;
runConfig.DashboardUpdateGranularity = "campaign";
for w = 1:height(windows)
    windowStart = windows.StartTime(w);
    windowFinish = windows.FinishTime(w);
    releaseWindow = localReleaseWindow(plan.ReleaseTable, windowStart, windowFinish, baseAnchor, config);
    if isempty(releaseWindow) || height(releaseWindow) == 0
        fprintf('Full-horizon weekly campaign %d/%d skipped: no releases in window.\n', ...
            w, height(windows));
        continue
    end

    weekInfo = campaignInfo;
    weekInfo.CampaignMode = "weeklyPart";
    weekInfo.WeekIndex = w;
    weekInfo.WeekStartTime = windowStart;
    weekInfo.WeekFinishTime = windowFinish;
    weekInfo.DisplayStartTime = windowStart;
    weekInfo.DisplayFinishTime = windowFinish;
    weekInfo.StartTime = baseAnchor;
    weekInfo.FinishTime = baseAnchor + (windowFinish - localWeekAnchor(windowStart));
    weekInfo.FinishTimeString = string(datestr(weekInfo.FinishTime, 'dd.mm.yyyy HH:MM:SS.0000'));
    weekInfo.HorizonHours = hours(weekInfo.FinishTime - weekInfo.StartTime);
    weekShiftTimes = localProductionShiftTimes(windowStart, windowFinish, config);
    weekInfo.ProductionShiftTimes = weekShiftTimes;
    weekInfo.FullHorizonProductionShiftTimes = fullShiftTimes;
    weekInfo.FullHorizonStartTime = campaignInfo.StartTime;
    weekInfo.FullHorizonFinishTime = campaignInfo.FinishTime;
    weekInfo.ProductionShiftCount = max(1, numel(weekShiftTimes));
    weekInfo.ProductionDayCount = max(1, numel(unique(dateshift(weekShiftTimes, 'start', 'day'))));
    weekInfo.TargetMultiplier = weekInfo.ProductionShiftCount / localNominalWeeklyShiftCount(config);
    weekInfo.CampaignTarget = weekInfo.WeeklyTarget * weekInfo.TargetMultiplier;

    fprintf('  Full-horizon weekly campaign %d/%d: %s to %s, release=%g parts.\n', ...
        w, height(windows), char(string(windowStart)), char(string(windowFinish)), ...
        sum(releaseWindow.Number, 'omitnan'));

    localWriteAndValidateDmInputs(releaseWindow, plan.RoutingTable, cycleTimeTable, pwd);
    runDir = pwd;
    if localShouldConfigureDigitalModel(config)
        localConfigureDigitalModelInputs(runDir);
    end
    [weekResult, weekSeeds, weekLiveLog] = localRunDigitalModelOnce( ...
        weekInfo.FinishTimeString, runConfig, weekInfo, useLiveRunner);
    weekResults{w} = weekResult;
    seedCells{w} = weekSeeds;
    liveLog = cpms.vertcatLoose(liveLog, weekLiveLog);
    localPlotWeeklyOfficialDmDashboardIfNeeded(weekResult, releaseWindow, ...
        plan, w, weekInfo, runConfig, useLiveRunner);
end

dmResult = localAggregateWeeklyDmResults(weekResults, max(1, round(double(config.DmReplications))));
seeds = localVertcatSeeds(seedCells);
end

function windows = localWeeklyWindows(startTime, finishTime, config)
starts = datetime.empty(0, 1);
finishes = datetime.empty(0, 1);
cursor = startTime;
while cursor < finishTime
    weekFinish = min(localWeeklyFinishTime(cursor, 1), finishTime);
    starts(end + 1, 1) = cursor; %#ok<AGROW>
    finishes(end + 1, 1) = weekFinish; %#ok<AGROW>
    cursor = localNextWeekStart(weekFinish, config);
end
windows = table(starts, finishes, 'VariableNames', {'StartTime', 'FinishTime'});
end

function nextStart = localNextWeekStart(t, config)
nextStart = dateshift(t, 'start', 'day') + days(1) + hours(6) + minutes(30);
while ~localIsProductionDay(nextStart, config)
    nextStart = dateshift(nextStart, 'start', 'day') + days(1) + hours(6) + minutes(30);
end
end

function anchor = localWeekAnchor(t)
d = dateshift(t, 'start', 'day');
daysSinceMonday = mod(weekday(d) - 2, 7);
anchor = d - days(daysSinceMonday) + hours(6) + minutes(30);
end

function tf = localIsProductionDay(t, config)
d = dateshift(t, 'start', 'day');
tf = ~ismember(weekday(d), [1 7]) & ~ismember(d, localCourseHolidays(config));
end

function holidays = localCourseHolidays(config)
if isfield(config, 'CourseHolidays') && ~isempty(config.CourseHolidays)
    holidays = dateshift(config.CourseHolidays(:), 'start', 'day');
else
    holidays = dateshift(datetime([2025 12 8; 2025 12 25; 2025 12 26]), 'start', 'day');
end
end

function releaseWindow = localReleaseWindow(releaseTable, windowStart, windowFinish, normalizedWeekAnchor, config)
releaseWindow = releaseTable(releaseTable.("Release Time") >= windowStart & ...
    releaseTable.("Release Time") < windowFinish, :);
if isempty(releaseWindow) || height(releaseWindow) == 0
    return
end
sourceWeekAnchor = localWeekAnchor(windowStart);
releaseWindow.("Release Time") = normalizedWeekAnchor + (releaseWindow.("Release Time") - sourceWeekAnchor);
keep = localIsProductionDay(releaseWindow.("Release Time"), config);
releaseWindow = releaseWindow(keep, :);
releaseWindow = sortrows(releaseWindow, "Release Time");
end

function aggregate = localAggregateWeeklyDmResults(weekResults, nruns)
aggregate = struct();
runNames = arrayfun(@(k) sprintf('run%d', k), 1:nruns, 'UniformOutput', false);
for r = 1:nruns
    runName = runNames{r};
    pieces = {};
    for w = 1:numel(weekResults)
        if isstruct(weekResults{w}) && isfield(weekResults{w}, runName)
            pieces{end + 1} = weekResults{w}.(runName); %#ok<AGROW>
        end
    end
    aggregate.(runName) = localAggregateWeeklyRunPieces(pieces);
end
end

function out = localAggregateWeeklyRunPieces(pieces)
fields = {'DailyCumProd', 'SigmaCumProd', 'MachSat', 'AvgBuffLevel', 'AvgLeadTime', 'ThPerShift'};
out = struct();
for i = 1:numel(fields)
    out.(fields{i}) = [];
end
if isempty(pieces)
    return
end
out.DailyCumProd = localVertcatField(pieces, 'DailyCumProd');
out.ThPerShift = localVertcatField(pieces, 'ThPerShift');
out.SigmaCumProd = localMeanVectorField(pieces, 'SigmaCumProd');
out.MachSat = localMeanVectorField(pieces, 'MachSat');
out.AvgBuffLevel = localMeanVectorField(pieces, 'AvgBuffLevel');
out.AvgLeadTime = localMeanVectorField(pieces, 'AvgLeadTime');
end

function M = localVertcatField(pieces, fieldName)
M = [];
for i = 1:numel(pieces)
    if isstruct(pieces{i}) && isfield(pieces{i}, fieldName) && ~isempty(pieces{i}.(fieldName))
        M = [M; double(pieces{i}.(fieldName))]; %#ok<AGROW>
    end
end
end

function v = localMeanVectorField(pieces, fieldName)
cols = {};
for i = 1:numel(pieces)
    if isstruct(pieces{i}) && isfield(pieces{i}, fieldName) && ~isempty(pieces{i}.(fieldName))
        cols{end + 1} = double(pieces{i}.(fieldName)(:)); %#ok<AGROW>
    end
end
if isempty(cols)
    v = [];
    return
end
maxRows = max(cellfun(@numel, cols));
stack = NaN(maxRows, numel(cols));
for i = 1:numel(cols)
    stack(1:numel(cols{i}), i) = cols{i};
end
v = mean(stack, 2, 'omitnan');
end

function seeds = localVertcatSeeds(seedCells)
seeds = [];
for i = 1:numel(seedCells)
    if ~isempty(seedCells{i})
        seeds = [seeds; seedCells{i}(:)]; %#ok<AGROW>
    end
end
end

function genome = localBaseGenome(releaseTable, routingTable, config)
releaseGenes = zeros(1, 5);
if ~isempty(releaseTable) && height(releaseTable) > 0
    pt = string(releaseTable.("Part Type"));
    qty = double(releaseTable.Number);
    for i = 1:5
        releaseGenes(i) = sum(qty(pt == "PT" + string(i)), 'omitnan');
    end
end

R = double(table2array(routingTable(:, 2:end)));
routingGenes = zeros(1, 14);
for g = 1:numel(config.StageMachineGroups)
    cols = config.StageMachineGroups{g};
    values = R(:, cols);
    rowSums = sum(values, 2);
    values = values(rowSums > 0, :);
    if isempty(values)
        routingGenes(cols) = 1;
    else
        routingGenes(cols) = mean(values, 1, 'omitnan');
    end
end

genome = localRepairGenome([releaseGenes routingGenes], config);
end

function plan = localGenomeToPlan(genome, templateRelease, config, source)
genome = localRepairGenome(genome, config);
shiftStart = localReleaseStart(templateRelease, config);

finishTime = localFinishTime(shiftStart, config);
if localUseTrainedPolicyOnly(config) && localCampaignMode(config) == "shift"
    releaseTable = localPolicyShiftReleaseTable(shiftStart, genome, templateRelease, config);
    routingTable = localGenomeToRouting(genome, config);

    plan = struct();
    plan.ReleaseTable = releaseTable;
    plan.RoutingTable = routingTable;
    plan.Genome = genome;
    plan.Source = source;
    return
end

if localUseCampaignReleaseSchedule(shiftStart, finishTime, config)
    releaseTable = localCampaignReleaseTable(shiftStart, finishTime, genome, config);
    routingTable = localGenomeToRouting(genome, config);

    plan = struct();
    plan.ReleaseTable = releaseTable;
    plan.RoutingTable = routingTable;
    plan.Genome = genome;
    plan.Source = source;
    return
end

releaseTime = datetime.empty(0, 1);
partType = strings(0, 1);
number = zeros(0, 1);
slot = 0;
for i = 1:5
    qty = round(genome(i));
    if qty <= 0
        continue
    end
    releaseTime(end + 1, 1) = shiftStart + minutes(slot); %#ok<AGROW>
    partType(end + 1, 1) = "PT" + string(i); %#ok<AGROW>
    number(end + 1, 1) = qty; %#ok<AGROW>
    slot = slot + config.ReleaseSpacingMinutes;
end
if isempty(releaseTime)
    releaseTime(1, 1) = shiftStart;
    partType(1, 1) = "PT1";
    number(1, 1) = config.MinLot;
end

releaseTable = table(releaseTime, partType, number, ...
    'VariableNames', {'Release Time', 'Part Type', 'Number'});
routingTable = localGenomeToRouting(genome, config);

plan = struct();
plan.ReleaseTable = releaseTable;
plan.RoutingTable = routingTable;
plan.Genome = genome;
plan.Source = source;
end

function releaseTable = localPolicyShiftReleaseTable(shiftStart, genome, templateRelease, config)
productTypes = string(config.ProductTypes(:));
baseQty = localTemplateReleaseQuantities(templateRelease, config);
targetQty = localTargetVector(config) / localNominalWeeklyShiftCount(config);
missingBase = ~isfinite(baseQty) | baseQty <= 0;
baseQty(missingBase) = targetQty(missingBase);

geneCap = config.MaxReleasePerPart(:)';
if numel(geneCap) < 5
    geneCap(end + 1:5) = geneCap(end);
end
geneCap = max(1, geneCap(1:5));

releasePressure = localReleasePressure( ...
    genome(1:5), geneCap, config, 'ShiftReleasePressureMin', 'ShiftReleasePressureMax', 0.75, 1.15);
priority = localReleasePriorityByPart(config);
qty = round(baseQty(:)' .* releasePressure .* priority);
qty(~isfinite(qty) | qty < 0) = 0;
for i = 1:numel(qty)
    if qty(i) > 0 && qty(i) < config.MinLot
        qty(i) = config.MinLot;
    end
end

releaseTime = datetime.empty(0, 1);
partType = strings(0, 1);
number = zeros(0, 1);
slot = 0;
for p = 1:min(5, numel(productTypes))
    if qty(p) <= 0
        continue
    end
    releaseTime(end + 1, 1) = shiftStart + minutes(slot); %#ok<AGROW>
    partType(end + 1, 1) = productTypes(p); %#ok<AGROW>
    number(end + 1, 1) = qty(p); %#ok<AGROW>
    slot = slot + config.ReleaseSpacingMinutes;
end

if isempty(releaseTime)
    releaseTime(1, 1) = shiftStart;
    partType(1, 1) = productTypes(1);
    number(1, 1) = config.MinLot;
end

releaseTable = table(releaseTime, partType, number, ...
    'VariableNames', {'Release Time', 'Part Type', 'Number'});
end

function qty = localTemplateReleaseQuantities(templateRelease, config)
qty = nan(1, 5);
if isempty(templateRelease) || ~istable(templateRelease) || ...
        ~all(ismember(["Part Type", "Number"], string(templateRelease.Properties.VariableNames)))
    return
end
pt = string(templateRelease.("Part Type"));
number = double(templateRelease.Number);
for i = 1:min(5, numel(config.ProductTypes))
    qty(i) = sum(number(pt == "PT" + string(i)), 'omitnan');
end
end

function priority = localReleasePriorityByPart(config)
priority = ones(1, 5);
if isfield(config, 'ReleasePriorityByPart') && isnumeric(config.ReleasePriorityByPart) && ...
        ~isempty(config.ReleasePriorityByPart)
    values = double(config.ReleasePriorityByPart(:))';
    n = min(5, numel(values));
    priority(1:n) = values(1:n);
end
priority(~isfinite(priority) | priority <= 0) = 1;
end

function pressure = localReleasePressure(genes, geneCap, config, minField, maxField, fallbackMin, fallbackMax)
ratio = max(0, min(1, double(genes(:)') ./ double(geneCap(:)')));
minPressure = localConfigNumber(config, minField, fallbackMin);
maxPressure = localConfigNumber(config, maxField, fallbackMax);
if maxPressure < minPressure
    tmp = minPressure;
    minPressure = maxPressure;
    maxPressure = tmp;
end
pressure = minPressure + (maxPressure - minPressure) .* ratio;
end

function tf = localUseCampaignReleaseSchedule(startTime, finishTime, config)
mode = localCampaignMode(config);
horizonHours = hours(finishTime - startTime);
tf = (mode == "weekly" || mode == "full" || mode == "final" || mode == "customhours") && ...
    horizonHours > 1.5 * max(1, double(config.ShiftLengthHours));
tf = tf || localUseTrainedPolicyOnly(config);
end

function releaseTable = localCampaignReleaseTable(startTime, finishTime, genome, config)
releaseTimes = localProductionShiftTimes(startTime, finishTime, config);
if isempty(releaseTimes)
    releaseTimes = startTime;
end

mode = localEffectiveCampaignMode(config, startTime, finishTime);
horizonHours = hours(finishTime - startTime);
campaignTarget = localTargetVector(config) * localCampaignTargetMultiplier(mode, horizonHours);
geneCap = config.MaxReleasePerPart(:)';
if numel(geneCap) < 5
    geneCap(end + 1:5) = geneCap(end);
end
geneCap = max(1, geneCap(1:5));

% The GA genes represent release pressure. For multi-day campaigns, explore a
% deliberately wider range so the DM can learn when extra releases only inflate
% WIP and when PT5 needs additional pressure.
releasePressure = localReleasePressure( ...
    genome(1:5), geneCap, config, 'CampaignReleasePressureMin', 'CampaignReleasePressureMax', 0.60, 1.25);
priority = localReleasePriorityByPart(config);
totalQty = round(campaignTarget(:)' .* releasePressure .* priority);
totalQty(~isfinite(totalQty) | totalQty < 0) = 0;

releaseTime = datetime.empty(0, 1);
partType = strings(0, 1);
number = zeros(0, 1);
nSlots = numel(releaseTimes);
for p = 1:5
    qty = totalQty(p);
    if qty <= 0
        continue
    end
    baseQty = floor(qty / nSlots);
    extra = mod(qty, nSlots);
    for s = 1:nSlots
        lotQty = baseQty + double(s <= extra);
        if lotQty <= 0
            continue
        end
        releaseTime(end + 1, 1) = releaseTimes(s) + minutes((p - 1) * config.ReleaseSpacingMinutes); %#ok<AGROW>
        partType(end + 1, 1) = "PT" + string(p); %#ok<AGROW>
        number(end + 1, 1) = lotQty; %#ok<AGROW>
    end
end

if isempty(releaseTime)
    releaseTime(1, 1) = startTime;
    partType(1, 1) = "PT1";
    number(1, 1) = config.MinLot;
end

releaseTable = table(releaseTime, partType, number, ...
    'VariableNames', {'Release Time', 'Part Type', 'Number'});
releaseTable = sortrows(releaseTable, "Release Time");
end

function times = localProductionShiftTimes(startTime, finishTime, config)
times = datetime.empty(0, 1);
day = dateshift(startTime, 'start', 'day');
lastDay = dateshift(finishTime, 'start', 'day');
while day <= lastDay
    if localIsProductionDay(day, config)
        if isfield(config, 'ValidShiftStarts') && ~isempty(config.ValidShiftStarts)
            shiftStarts = config.ValidShiftStarts;
        else
            shiftStarts = [duration(6, 30, 0), duration(14, 30, 0)];
        end
        candidates = day + shiftStarts;
        for i = 1:numel(candidates)
            if candidates(i) >= startTime && candidates(i) < finishTime
                times(end + 1, 1) = candidates(i); %#ok<AGROW>
            end
        end
    end
    day = day + days(1);
end
end

function mode = localEffectiveCampaignMode(config, startTime, finishTime)
mode = localCampaignMode(config);
if mode == "weekly" && isfield(config, 'DmHorizonHours') && ...
        abs(double(config.DmHorizonHours) - 8) > eps
    mode = "customhours";
end
if mode == "customhours" && hours(finishTime - startTime) >= 7 * 24
    mode = "full";
end
end

function routingTable = localGenomeToRouting(genome, config)
partTypes = string(config.ProductTypes(:));
machines = string(config.Machines(:))';
R = zeros(numel(partTypes), numel(machines));

for i = 1:numel(partTypes)
    for g = 1:numel(config.StageMachineGroups)
        cols = config.StageMachineGroups{g};
        if g == 3 && ismember(partTypes(i), config.SkipStage3Parts)
            R(i, cols) = 0;
        else
            R(i, cols) = localNormalize100(genome(5 + cols));
        end
    end
end

routingTable = array2table(R, 'VariableNames', cellstr(machines));
routingTable = addvars(routingTable, partTypes, 'Before', 1, 'NewVariableNames', 'PT');
end

function population = localNextPopulation(trainingState, baseGenome, config)
popSize = max(config.GaPopulationSize, config.NumReleaseCandidates);
dim = numel(baseGenome);
population = zeros(popSize, dim);
evalSize = min(popSize, max(1, round(double(config.NumReleaseCandidates))));

writeIdx = 1;
population(writeIdx, :) = baseGenome;
writeIdx = writeIdx + 1;

if isfield(trainingState, 'BestGenome') && numel(trainingState.BestGenome) == dim && ...
        writeIdx <= evalSize && ~localGenomeAlreadyQueued(population, writeIdx - 1, trainingState.BestGenome)
    population(writeIdx, :) = trainingState.BestGenome;
    writeIdx = writeIdx + 1;
end

anchor = population(1, :);
if isfield(trainingState, 'BestGenome') && numel(trainingState.BestGenome) == dim
    anchor = trainingState.BestGenome;
end

if isfield(trainingState, 'Population') && isfield(trainingState, 'Scores') && ...
        size(trainingState.Population, 2) == dim && ~isempty(trainingState.Scores)
    [~, order] = sort(trainingState.Scores, 'descend', 'MissingPlacement', 'last');
    minFreshInEvaluatedSet = min(2, max(0, evalSize - 2));
    carryoverSlots = max(0, evalSize - writeIdx + 1 - minFreshInEvaluatedSet);
    eliteN = min([config.GaEliteCount, numel(order), carryoverSlots]);
    for i = 1:eliteN
        candidate = trainingState.Population(order(i), :);
        if isfinite(trainingState.Scores(order(i))) && ...
                ~localGenomeAlreadyQueued(population, writeIdx - 1, candidate)
            population(writeIdx, :) = trainingState.Population(order(i), :);
            writeIdx = writeIdx + 1;
        end
    end
end

while writeIdx <= popSize
    if rand < config.GaRandomImmigrantFraction
        child = localRandomGenome(baseGenome, config);
    else
        child = localMutateGenome(anchor, config);
    end
    population(writeIdx, :) = child;
    writeIdx = writeIdx + 1;
end

for i = 1:size(population, 1)
    population(i, :) = localRepairGenome(population(i, :), config);
end
end

function tf = localGenomeAlreadyQueued(population, lastRow, genome)
tf = false;
if lastRow <= 0
    return
end
existing = population(1:lastRow, :);
tf = any(all(abs(existing - double(genome(:))') < 1e-9, 2));
end

function trainingState = localUpdateTrainingState(trainingState, plans, scores, config)
genomes = vertcat(plans.Genome);
trainingState.Generation = trainingState.Generation + 1;
trainingState.Population = genomes;
rankScores = localRankScores(scores);
trainingState.Scores = rankScores;
trainingState.LastScores = scores;
trainingState.UpdatedAt = datetime('now');

valid = find(isfinite(rankScores));
if ~isempty(valid)
    [bestRankScore, localIdx] = max(rankScores(valid));
    bestIdx = valid(localIdx);
    if ~isfield(trainingState, 'BestNormalizedScore') || ~isfinite(trainingState.BestNormalizedScore) || ...
            bestRankScore > trainingState.BestNormalizedScore
        trainingState.BestNormalizedScore = bestRankScore;
        trainingState.BestScore = scores.Score(bestIdx);
        trainingState.BestGenome = plans(bestIdx).Genome;
    end
end

bestScoreThisRun = max(scores.Score, [], 'omitnan');
bestNormalizedThisRun = max(rankScores, [], 'omitnan');
ok = scores.Status == "ok";
campaignMode = "";
horizonHours = NaN;
startTime = NaT;
finishTime = NaT;
if any(ok)
    firstOk = find(ok, 1);
    campaignMode = scores.CampaignMode(firstOk);
    horizonHours = scores.HorizonHours(firstOk);
    startTime = scores.StartTime(firstOk);
    finishTime = scores.FinishTime(firstOk);
end

historyRow = table(datetime('now'), trainingState.Generation, ...
    campaignMode, horizonHours, startTime, finishTime, ...
    trainingState.BestScore, trainingState.BestNormalizedScore, ...
    bestScoreThisRun, bestNormalizedThisRun, ...
    sum(ok), height(scores), ...
    'VariableNames', {'Timestamp', 'Generation', 'CampaignMode', ...
    'HorizonHours', 'StartTime', 'FinishTime', 'BestScoreEver', ...
    'BestNormalizedScoreEver', 'BestScoreThisRun', ...
    'BestNormalizedScoreThisRun', 'OkCandidates', 'TotalCandidates'});
if isfield(trainingState, 'History') && istable(trainingState.History)
    trainingState.History = cpms.vertcatLoose(trainingState.History, historyRow);
else
    trainingState.History = historyRow;
end

cpms.ensureDir(fileparts(config.TrainingStateFile));
save(config.TrainingStateFile, 'trainingState');
try
    writetable(trainingState.History, config.TrainingHistoryFile);
catch
end
end

function rankScores = localRankScores(scores)
if istable(scores) && ismember('NormalizedScore', scores.Properties.VariableNames)
    rankScores = scores.NormalizedScore;
    missing = ~isfinite(rankScores);
    if ismember('Score', scores.Properties.VariableNames)
        rankScores(missing) = scores.Score(missing);
    end
else
    rankScores = scores.Score;
end
end

function trainingState = localLoadTrainingState(config)
expectedVersion = 7;
if isfield(config, 'GaStateVersion') && ~isempty(config.GaStateVersion)
    expectedVersion = round(double(config.GaStateVersion(1)));
end
trainingState = struct();
trainingState.Version = expectedVersion;
trainingState.Generation = 0;
trainingState.BestScore = -Inf;
trainingState.BestNormalizedScore = -Inf;
trainingState.BestGenome = [];
trainingState.Population = [];
trainingState.Scores = [];
trainingState.History = table();

if isfield(config, 'TrainingStateFile') && isfile(config.TrainingStateFile)
    try
        loaded = load(config.TrainingStateFile, 'trainingState');
        if isfield(loaded, 'trainingState') && isstruct(loaded.trainingState)
            loadedVersion = localStateVersion(loaded.trainingState);
            if loadedVersion == expectedVersion
                trainingState = cpms.mergeStruct(trainingState, loaded.trainingState);
            end
        end
    catch
    end
end
end

function version = localStateVersion(trainingState)
version = NaN;
if isstruct(trainingState) && isfield(trainingState, 'Version') && ~isempty(trainingState.Version)
    version = double(trainingState.Version);
end
end

function localAppendDmProductionLog(dmResult, plan, candidateIndex, score, normalizedScore, campaignInfo, liveLog, config)
if ~isfield(config, 'DmProductionLogFile') || strlength(string(config.DmProductionLogFile)) == 0
    return
end

try
    cpms.ensureDir(fileparts(config.DmProductionLogFile));
    runId = string(datestr(now, 'yyyymmdd_HHMMSS_FFF'));
    timestamp = datetime('now');

    shiftRuns = localRowsByReplication(dmResult, 'ThPerShift', runId, timestamp, ...
        candidateIndex, score, normalizedScore, campaignInfo, 'ShiftIndex');
    dailyRuns = localRowsByReplication(dmResult, 'DailyCumProd', runId, timestamp, ...
        candidateIndex, score, normalizedScore, campaignInfo, 'DayIndex');
    shiftAvg = localRowsAverage(dmResult, 'ThPerShift', runId, timestamp, ...
        candidateIndex, score, normalizedScore, campaignInfo, 'ShiftIndex');
    dailyAvg = localRowsAverage(dmResult, 'DailyCumProd', runId, timestamp, ...
        candidateIndex, score, normalizedScore, campaignInfo, 'DayIndex');
    cumulativeRuns = localCumulativeRows(dailyRuns, 'DayIndex');
    cumulativeAvg = localCumulativeRows(dailyAvg, 'DayIndex');
    kpiRuns = localKpiRowsByReplication(dmResult, runId, timestamp, ...
        candidateIndex, score, normalizedScore, campaignInfo);
    kpiAvg = localKpiRowsAverage(dmResult, runId, timestamp, ...
        candidateIndex, score, normalizedScore, campaignInfo);
    releasePlan = localReleaseRows(plan.ReleaseTable, runId, timestamp, ...
        candidateIndex, score, normalizedScore, campaignInfo);
    routingPlan = localRoutingRows(plan.RoutingTable, runId, timestamp, ...
        candidateIndex, score, normalizedScore, campaignInfo);
    candidateSummary = localCandidateSummary(plan, runId, timestamp, ...
        candidateIndex, score, normalizedScore, campaignInfo);
    liveRows = localLiveRows(liveLog, runId, timestamp);

    localAppendSheetSafe(config.DmProductionLogFile, 'CandidateSummary', candidateSummary);
    localAppendSheetSafe(config.DmProductionLogFile, 'KPI_Avg', kpiAvg);
    localAppendSheetSafe(config.DmProductionLogFile, 'KPI_Runs', kpiRuns);
    localAppendSheetSafe(config.DmProductionLogFile, 'ThPerShift_Runs', shiftRuns);
    localAppendSheetSafe(config.DmProductionLogFile, 'DailyCumProd_Runs', dailyRuns);
    localAppendSheetSafe(config.DmProductionLogFile, 'CumulativeProd_Runs', cumulativeRuns);
    localAppendSheetSafe(config.DmProductionLogFile, 'ThPerShift_Avg', shiftAvg);
    localAppendSheetSafe(config.DmProductionLogFile, 'DailyCumProd_Avg', dailyAvg);
    localAppendSheetSafe(config.DmProductionLogFile, 'CumulativeProd_Avg', cumulativeAvg);
    localAppendSheetSafe(config.DmProductionLogFile, 'LivePolls', liveRows);
    localAppendSheetSafe(config.DmProductionLogFile, 'ReleasePlan', releasePlan);
    localAppendSheetSafe(config.DmProductionLogFile, 'RoutingPlan', routingPlan);
catch logError
    warning('cpms:DmProductionLogFailed', ...
        'Could not write DM production log: %s', logError.message);
end
end

function localAppendSheetSafe(filePath, sheetName, newRows)
try
    localAppendSheet(filePath, sheetName, newRows);
catch sheetError
    warning('cpms:DmProductionLogSheetFailed', ...
        'Could not write DM production log sheet %s: %s', ...
        sheetName, sheetError.message);
end
end

function rows = localRowsByReplication(dmResult, fieldName, runId, timestamp, candidateIndex, score, normalizedScore, campaignInfo, indexName)
runs = localRunNames(dmResult);
rows = table();
for r = 1:numel(runs)
    current = dmResult.(runs{r});
    if ~isfield(current, fieldName) || isempty(current.(fieldName))
        continue
    end
    M = double(current.(fieldName));
    rows = [rows; localMatrixRows(M, runId, timestamp, candidateIndex, ...
        string(runs{r}), score, normalizedScore, campaignInfo, indexName)]; %#ok<AGROW>
end
end

function rows = localRowsAverage(dmResult, fieldName, runId, timestamp, candidateIndex, score, normalizedScore, campaignInfo, indexName)
[avg, ok] = localAverageMatrix(dmResult, fieldName);
if ~ok
    rows = table();
    return
end
rows = localMatrixRows(avg, runId, timestamp, candidateIndex, "avg", score, normalizedScore, campaignInfo, indexName);
end

function rows = localMatrixRows(M, runId, timestamp, candidateIndex, replication, score, normalizedScore, campaignInfo, indexName)
if isempty(M)
    rows = table();
    return
end
n = size(M, 1);
if size(M, 2) < 5
    M(:, end + 1:5) = NaN;
end
rows = table( ...
    repmat(runId, n, 1), ...
    repmat(timestamp, n, 1), ...
    repmat(candidateIndex, n, 1), ...
    repmat(replication, n, 1), ...
    (1:n)', ...
    M(:, 1), M(:, 2), M(:, 3), M(:, 4), M(:, 5), ...
    sum(M(:, 1:5), 2, 'omitnan'), ...
    repmat(score, n, 1), ...
    repmat(normalizedScore, n, 1), ...
    repmat(string(campaignInfo.CampaignMode), n, 1), ...
    repmat(campaignInfo.HorizonHours, n, 1), ...
    repmat(campaignInfo.StartTime, n, 1), ...
    repmat(campaignInfo.FinishTime, n, 1), ...
    repmat(string(campaignInfo.FinishTimeString), n, 1), ...
    'VariableNames', {'RunId', 'Timestamp', 'Candidate', 'Replication', ...
    indexName, 'PT1', 'PT2', 'PT3', 'PT4', 'PT5', 'Total', 'Score', ...
    'NormalizedScore', 'CampaignMode', 'HorizonHours', 'StartTime', ...
    'FinishTime', 'FinishTimeString'});
end

function rows = localCumulativeRows(rows, indexName)
if isempty(rows) || height(rows) == 0
    return
end
ptNames = {'PT1', 'PT2', 'PT3', 'PT4', 'PT5'};
keys = string(rows.RunId) + "|" + string(rows.Candidate) + "|" + string(rows.Replication);
uniqueKeys = unique(keys, 'stable');
for i = 1:numel(uniqueKeys)
    idx = find(keys == uniqueKeys(i));
    [~, order] = sort(rows.(indexName)(idx));
    orderedIdx = idx(order);
    values = rows{orderedIdx, ptNames};
    values(~isfinite(values)) = 0;
    values = cumsum(values, 1);
    rows{orderedIdx, ptNames} = values;
    rows.Total(orderedIdx) = sum(values, 2);
end
end

function [avg, ok] = localAverageMatrix(dmResult, fieldName)
runs = localRunNames(dmResult);
maxRows = 0;
maxCols = 5;
matrices = cell(numel(runs), 1);
for r = 1:numel(runs)
    current = dmResult.(runs{r});
    if ~isfield(current, fieldName) || isempty(current.(fieldName))
        continue
    end
    M = double(current.(fieldName));
    maxRows = max(maxRows, size(M, 1));
    maxCols = max(maxCols, size(M, 2));
    matrices{r} = M;
end

if maxRows == 0
    avg = [];
    ok = false;
    return
end

stack = NaN(maxRows, maxCols, numel(runs));
for r = 1:numel(runs)
    M = matrices{r};
    if isempty(M)
        continue
    end
    stack(1:size(M, 1), 1:size(M, 2), r) = M;
end
avg = mean(stack, 3, 'omitnan');
ok = true;
end

function names = localRunNames(dmResult)
if ~isstruct(dmResult)
    names = {};
    return
end
names = fieldnames(dmResult);
names = names(startsWith(string(names), "run"));
end

function rows = localKpiRowsByReplication(dmResult, runId, timestamp, candidateIndex, score, normalizedScore, campaignInfo)
runs = localRunNames(dmResult);
rows = table();
for r = 1:numel(runs)
    rows = [rows; localKpiRow(dmResult.(runs{r}), runId, timestamp, ...
        candidateIndex, string(runs{r}), score, normalizedScore, campaignInfo)]; %#ok<AGROW>
end
end

function rows = localKpiRowsAverage(dmResult, runId, timestamp, candidateIndex, score, normalizedScore, campaignInfo)
avg = struct();
fields = {'DailyCumProd', 'SigmaCumProd', 'MachSat', 'AvgBuffLevel', ...
    'AvgLeadTime', 'ThPerShift'};
hasAny = false;
for i = 1:numel(fields)
    [value, ok] = localAverageMatrix(dmResult, fields{i});
    avg.(fields{i}) = value;
    hasAny = hasAny || ok;
end
if ~hasAny
    rows = table();
    return
end
rows = localKpiRow(avg, runId, timestamp, candidateIndex, "avg", ...
    score, normalizedScore, campaignInfo);
end

function row = localKpiRow(current, runId, timestamp, candidateIndex, replication, score, normalizedScore, campaignInfo)
throughput = nan(1, 5);
dailyProduction = nan(1, 5);
dailyLast = nan(1, 5);
sigma = nan(1, 5);
lead = nan(1, 5);
machSat = nan(1, 14);
avgBuff = nan(1, 14);
seed = NaN;

if isfield(current, 'Seed') && ~isempty(current.Seed)
    seed = double(current.Seed(1));
end
if isfield(current, 'ThPerShift') && ~isempty(current.ThPerShift)
    M = double(current.ThPerShift);
    cols = min(5, size(M, 2));
    throughput(1:cols) = sum(M(:, 1:cols), 1, 'omitnan');
end
if isfield(current, 'DailyCumProd') && ~isempty(current.DailyCumProd)
    M = double(current.DailyCumProd);
    cols = min(5, size(M, 2));
    dailyProduction(1:cols) = sum(M(:, 1:cols), 1, 'omitnan');
    dailyLast(1:cols) = M(end, 1:cols);
end
if isfield(current, 'SigmaCumProd') && ~isempty(current.SigmaCumProd)
    values = double(current.SigmaCumProd(:))';
    sigma(1:min(5, numel(values))) = values(1:min(5, numel(values)));
end
if isfield(current, 'AvgLeadTime') && ~isempty(current.AvgLeadTime)
    values = double(current.AvgLeadTime(:))';
    lead(1:min(5, numel(values))) = values(1:min(5, numel(values)));
end
if isfield(current, 'MachSat') && ~isempty(current.MachSat)
    values = double(current.MachSat(:))';
    machSat(1:min(14, numel(values))) = values(1:min(14, numel(values)));
end
if isfield(current, 'AvgBuffLevel') && ~isempty(current.AvgBuffLevel)
    values = double(current.AvgBuffLevel(:))';
    avgBuff(1:min(14, numel(values))) = values(1:min(14, numel(values)));
end

metricValues = [ ...
    sum(dailyProduction, 'omitnan'), ...
    sum(throughput, 'omitnan'), ...
    sum(avgBuff, 'omitnan'), ...
    mean(lead, 'omitnan'), ...
    mean(machSat, 'omitnan'), ...
    throughput, dailyProduction, dailyLast, sigma, lead, machSat, avgBuff];
metricNames = [{'TotalProduction', 'TotalThroughput', 'WipProxy', 'MeanLeadTimeHours', ...
    'MeanMachineSaturation'}, ...
    cellstr("Throughput_PT" + string(1:5)), ...
    cellstr("DailyProduction_PT" + string(1:5)), ...
    cellstr("DailyLast_PT" + string(1:5)), ...
    cellstr("SigmaCumProd_PT" + string(1:5)), ...
    cellstr("AvgLeadTime_PT" + string(1:5)), ...
    cellstr("MachSat_M" + string(1:14)), ...
    cellstr("AvgBuffLevel_M" + string(1:14))];

base = table(runId, timestamp, candidateIndex, replication, score, ...
    normalizedScore, seed, string(campaignInfo.CampaignMode), campaignInfo.HorizonHours, ...
    campaignInfo.StartTime, campaignInfo.FinishTime, string(campaignInfo.FinishTimeString), ...
    'VariableNames', {'RunId', 'Timestamp', 'Candidate', 'Replication', ...
    'Score', 'NormalizedScore', 'Seed', 'CampaignMode', 'HorizonHours', ...
    'StartTime', 'FinishTime', 'FinishTimeString'});
row = [base array2table(metricValues, 'VariableNames', metricNames)];
end

function rows = localReleaseRows(releaseTable, runId, timestamp, candidateIndex, score, normalizedScore, campaignInfo)
if isempty(releaseTable)
    rows = table();
    return
end
n = height(releaseTable);
rows = table( ...
    repmat(runId, n, 1), ...
    repmat(timestamp, n, 1), ...
    repmat(candidateIndex, n, 1), ...
    releaseTable.("Release Time"), ...
    string(releaseTable.("Part Type")), ...
    double(releaseTable.Number), ...
    repmat(score, n, 1), ...
    repmat(normalizedScore, n, 1), ...
    repmat(string(campaignInfo.CampaignMode), n, 1), ...
    repmat(campaignInfo.HorizonHours, n, 1), ...
    repmat(campaignInfo.StartTime, n, 1), ...
    repmat(campaignInfo.FinishTime, n, 1), ...
    'VariableNames', {'RunId', 'Timestamp', 'Candidate', 'ReleaseTime', ...
    'PartType', 'Number', 'Score', 'NormalizedScore', 'CampaignMode', ...
        'HorizonHours', 'StartTime', 'FinishTime'});
end

function rows = localRoutingRows(routingTable, runId, timestamp, candidateIndex, score, normalizedScore, campaignInfo)
if isempty(routingTable) || ~istable(routingTable)
    rows = table();
    return
end

machineNames = "M" + string(1:14);
if ~all(ismember(["PT", machineNames], string(routingTable.Properties.VariableNames)))
    rows = table();
    return
end

n = height(routingTable);
machineValues = routingTable{:, cellstr(machineNames)};
rows = table( ...
    repmat(runId, n, 1), ...
    repmat(timestamp, n, 1), ...
    repmat(candidateIndex, n, 1), ...
    string(routingTable.PT), ...
    repmat(score, n, 1), ...
    repmat(normalizedScore, n, 1), ...
    repmat(string(campaignInfo.CampaignMode), n, 1), ...
    repmat(campaignInfo.HorizonHours, n, 1), ...
    repmat(campaignInfo.StartTime, n, 1), ...
    repmat(campaignInfo.FinishTime, n, 1), ...
    'VariableNames', {'RunId', 'Timestamp', 'Candidate', 'PT', ...
    'Score', 'NormalizedScore', 'CampaignMode', 'HorizonHours', ...
    'StartTime', 'FinishTime'});
rows = [rows array2table(machineValues, 'VariableNames', cellstr(machineNames))];
end

function row = localCandidateSummary(plan, runId, timestamp, candidateIndex, score, normalizedScore, campaignInfo)
[totals, totalRelease] = localReleaseTotals(plan.ReleaseTable);
campaignTarget = localStructField(campaignInfo, 'CampaignTarget', nan(1, 5));
targetMultiplier = localStructField(campaignInfo, 'TargetMultiplier', NaN);
row = table(runId, timestamp, candidateIndex, string(plan.Source), ...
    score, normalizedScore, campaignInfo.SimulatedShifts, ...
    string(campaignInfo.CampaignMode), campaignInfo.HorizonHours, targetMultiplier, ...
    campaignInfo.StartTime, campaignInfo.FinishTime, string(campaignInfo.FinishTimeString), ...
    height(plan.ReleaseTable), totalRelease, sum(campaignTarget, 'omitnan'), ...
    totals(1), totals(2), totals(3), totals(4), totals(5), ...
    campaignTarget(1), campaignTarget(2), campaignTarget(3), campaignTarget(4), campaignTarget(5), ...
    'VariableNames', {'RunId', 'Timestamp', 'Candidate', 'Source', 'Score', ...
    'NormalizedScore', 'SimulatedShifts', 'CampaignMode', 'HorizonHours', ...
    'TargetMultiplier', 'StartTime', 'FinishTime', 'FinishTimeString', 'ReleaseRows', ...
    'TotalRelease', 'CampaignTargetTotal', 'Release_PT1', 'Release_PT2', 'Release_PT3', ...
    'Release_PT4', 'Release_PT5', 'CampaignTarget_PT1', 'CampaignTarget_PT2', ...
    'CampaignTarget_PT3', 'CampaignTarget_PT4', 'CampaignTarget_PT5'});
end

function value = localStructField(s, fieldName, fallback)
if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = s.(fieldName);
else
    value = fallback;
end
end

function rows = localLiveRows(liveLog, runId, timestamp)
if isempty(liveLog) || height(liveLog) == 0
    rows = table();
    return
end
rows = liveLog;
rows = addvars(rows, repmat(runId, height(rows), 1), ...
    repmat(timestamp, height(rows), 1), 'Before', 1, ...
    'NewVariableNames', {'RunId', 'LoggedAt'});
end

function [totals, totalRelease] = localReleaseTotals(releaseTable)
totals = zeros(1, 5);
if isempty(releaseTable) || height(releaseTable) == 0
    totalRelease = 0;
    return
end
pt = string(releaseTable.("Part Type"));
qty = double(releaseTable.Number);
for i = 1:5
    totals(i) = sum(qty(pt == "PT" + string(i)), 'omitnan');
end
totalRelease = sum(totals, 'omitnan');
end

function localAppendSheet(filePath, sheetName, newRows)
if isempty(newRows) || height(newRows) == 0
    return
end
if isfile(filePath)
    try
        oldRows = readtable(filePath, 'Sheet', sheetName, ...
            'VariableNamingRule', 'preserve', 'TextType', 'string');
        newRows = cpms.vertcatLoose(oldRows, newRows);
    catch
    end
end
writetable(newRows, filePath, 'Sheet', sheetName);
end

function genome = localMutateGenome(parent, config)
genome = parent;
genome(1:5) = genome(1:5) + round(randn(1, 5) * config.GaMutationRelease);
genome(6:end) = genome(6:end) + randn(1, 14) * config.GaMutationRouting;
genome = localRepairGenome(genome, config);
end

function genome = localRandomGenome(baseGenome, config)
maxRelease = config.MaxReleasePerPart(:)';
genome = baseGenome;
genome(1:5) = round(rand(1, 5) .* maxRelease);
for g = 1:numel(config.StageMachineGroups)
    cols = config.StageMachineGroups{g};
    genome(5 + cols) = 1 + 99 * rand(1, numel(cols));
end
genome = localRepairGenome(genome, config);
end

function genome = localRepairGenome(genome, config)
genome = double(genome(:))';
maxRelease = config.MaxReleasePerPart(:)';
genome(1:5) = round(max(0, min(maxRelease, genome(1:5))));
for i = 1:5
    if genome(i) > 0 && genome(i) < config.MinLot
        genome(i) = config.MinLot;
    end
end
genome(6:end) = max(0.1, genome(6:end));
end

function pct = localNormalize100(weights)
weights = max(0, double(weights(:)'));
if sum(weights) <= 0
    weights = ones(size(weights));
end
raw = 100 * weights / sum(weights);
pct = floor(raw * 1000) / 1000;
[~, idx] = max(raw - pct);
pct(idx) = pct(idx) + (100 - sum(pct));
end

function startTime = localReleaseStart(templateRelease, config)
if ~isempty(config.ShiftStart)
    startTime = config.ShiftStart;
elseif ~isempty(templateRelease) && height(templateRelease) > 0 && ...
        ismember('Release Time', templateRelease.Properties.VariableNames)
    startTime = min(templateRelease.("Release Time"));
else
    startTime = dateshift(datetime('now'), 'start', 'hour');
end
end

function runDir = localPrepareDmRunDir(config)
if isfield(config, 'UseDmWorkingCopy') && config.UseDmWorkingCopy
    runDir = config.DmWorkDir;
    cpms.ensureDir(runDir);
    localCopyIfNewer(config.DmDir, runDir, 'dm_run.p');
    localCopyIfNewer(config.DmDir, runDir, 'dm_config.p');
    localCopyIfNewer(config.DmDir, runDir, 'validateReleaseTable.m');
    localCopyIfNewer(config.DmDir, runDir, 'validateRoutingTable.m');
    localCopyIfNewer(config.DmDir, runDir, 'validateCycleTimeTable.m');
    localCopyFirstMatch(config.DmDir, runDir, '*.spp');
else
    runDir = config.DmDir;
end
end

function localInstallSysState(sysState, runDir, config)
dst = fullfile(runDir, 'SysState.xlsx');

if isstruct(sysState) && isfield(sysState, 'File') && isfile(sysState.File)
    localSafeCopyInput(sysState.File, dst, 'SysState.xlsx');
    return
end

src = fullfile(config.DmDir, 'SysState.xlsx');
if isfile(src)
    localSafeCopyInput(src, dst, 'SysState.xlsx');
    return
end

if isstruct(sysState) && isfield(sysState, 'Primary') && istable(sysState.Primary)
    try
        writetable(sysState.Primary, dst);
    catch writeError
        if isfile(dst)
            warning('cpms:LockedSysStateUsingExisting', ...
                'Could not overwrite %s (%s). Using the existing working-copy SysState.xlsx.', ...
                dst, writeError.message);
        else
            rethrow(writeError);
        end
    end
    return
end

error('cpms:MissingSysStateForDm', ...
    'SysState.xlsx is required by the Digital Model but was not found.');
end

function localCopyIfNewer(srcDir, dstDir, name)
src = fullfile(srcDir, name);
dst = fullfile(dstDir, name);
if ~isfile(src)
    return
end
if ~isfile(dst) || dir(src).datenum > dir(dst).datenum
    localSafeCopyInput(src, dst, name);
end
end

function localCopyFirstMatch(srcDir, dstDir, pattern)
files = dir(fullfile(srcDir, pattern));
if isempty(files)
    return
end
[~, idx] = max([files.datenum]);
src = fullfile(files(idx).folder, files(idx).name);
dst = fullfile(dstDir, files(idx).name);
if ~isfile(dst) || dir(src).datenum > dir(dst).datenum
    localSafeCopyInput(src, dst, files(idx).name);
end
end

function localSafeCopyInput(src, dst, displayName)
if localSamePath(src, dst)
    return
end
try
    copyfile(src, dst);
catch copyError
    if isfile(dst)
        warning('cpms:LockedDmInputUsingExisting', ...
            'Could not overwrite %s (%s). Using the existing working-copy file.', ...
            displayName, copyError.message);
    else
        rethrow(copyError);
    end
end
end

function tf = localSamePath(a, b)
tf = false;
try
    fileA = java.io.File(char(a));
    fileB = java.io.File(char(b));
    tf = strcmpi(char(fileA.getCanonicalPath()), char(fileB.getCanonicalPath()));
catch
    try
        tf = strcmpi(char(string(a)), char(string(b)));
    catch
        tf = false;
    end
end
end

function campaignInfo = localCampaignInfo(candidate, config)
startTime = localReleaseStart(candidate, config);
finishTime = localFinishTime(startTime, config);
campaignMode = localEffectiveCampaignMode(config, startTime, finishTime);
shiftTimes = localProductionShiftTimes(startTime, finishTime, config);
if isempty(shiftTimes)
    productionDayCount = max(1, ceil(hours(finishTime - startTime) / 24));
else
    productionDayCount = numel(unique(dateshift(shiftTimes, 'start', 'day')));
end

campaignInfo = struct();
campaignInfo.CampaignMode = campaignMode;
campaignInfo.StartTime = startTime;
campaignInfo.FinishTime = finishTime;
campaignInfo.FinishTimeString = string(datestr(finishTime, 'dd.mm.yyyy HH:MM:SS.0000'));
campaignInfo.HorizonHours = hours(finishTime - startTime);
campaignInfo.WeeklyTarget = localTargetVector(config);
campaignInfo.TargetMultiplier = localCampaignTargetMultiplier(campaignInfo.CampaignMode, campaignInfo.HorizonHours);
campaignInfo.CampaignTarget = campaignInfo.WeeklyTarget * campaignInfo.TargetMultiplier;
campaignInfo.SimulatedShifts = max(1, ceil(campaignInfo.HorizonHours / max(1, config.ShiftLengthHours)));
campaignInfo.ProductionShiftCount = max(1, numel(shiftTimes));
campaignInfo.ProductionDayCount = productionDayCount;
campaignInfo.ProductionShiftTimes = shiftTimes;
campaignInfo.ShiftLengthHours = config.ShiftLengthHours;
end

function finishTime = localFinishTime(startTime, config)
mode = localCampaignMode(config);

if mode == "full" || mode == "final"
    if isfield(config, 'ProjectEndTime') && ~isempty(config.ProjectEndTime)
        finishTime = config.ProjectEndTime;
    else
        finishTime = startTime + hours(config.DmHorizonHours);
    end
elseif mode == "customhours" || (mode == "weekly" && isfield(config, 'DmHorizonHours') && ...
        abs(double(config.DmHorizonHours) - 8) > eps)
    finishTime = startTime + hours(config.DmHorizonHours);
elseif mode == "shift"
    finishTime = startTime + hours(config.ShiftLengthHours);
else
    weeks = 1;
    if isfield(config, 'TrainingCampaignWeeks') && ~isempty(config.TrainingCampaignWeeks)
        weeks = max(1, round(double(config.TrainingCampaignWeeks)));
    end
    finishTime = localWeeklyFinishTime(startTime, weeks);
end

if finishTime <= startTime
    finishTime = startTime + hours(max(1, config.ShiftLengthHours));
end
end

function mode = localCampaignMode(config)
if isfield(config, 'TrainingCampaignMode') && strlength(string(config.TrainingCampaignMode)) > 0
    mode = lower(string(config.TrainingCampaignMode));
else
    mode = "weekly";
end
end

function finishTime = localWeeklyFinishTime(startTime, weeks)
dayStart = dateshift(startTime, 'start', 'day');
dayOfWeek = weekday(startTime); % Sunday = 1, Friday = 6.
daysUntilFriday = mod(6 - dayOfWeek, 7);
finishTime = dayStart + days(daysUntilFriday + 7 * (weeks - 1)) + hours(22) + minutes(30);
if finishTime <= startTime
    finishTime = finishTime + days(7);
end
end

function n = localSimulatedShiftCount(dmResult, campaignInfo)
n = 0;
runs = localRunNames(dmResult);
for i = 1:numel(runs)
    current = dmResult.(runs{i});
    if isfield(current, 'ThPerShift') && ~isempty(current.ThPerShift)
        n = max(n, size(current.ThPerShift, 1));
    end
end
if n <= 0
    n = campaignInfo.SimulatedShifts;
end
end

function target = localTargetVector(config)
target = nan(1, 5);
if isfield(config, 'TargetByPart') && istable(config.TargetByPart)
    pt = string(config.TargetByPart.PartType);
    qty = double(config.TargetByPart.TargetQty);
    for i = 1:5
        idx = find(pt == "PT" + string(i), 1);
        if ~isempty(idx)
            target(i) = qty(idx);
        end
    end
end
end

function multiplier = localCampaignTargetMultiplier(mode, horizonHours)
mode = lower(string(mode));
if mode == "weekly"
    multiplier = 1;
elseif mode == "full" || mode == "final"
    multiplier = max(1, ceil(double(horizonHours) / (7 * 24)));
elseif mode == "shift"
    multiplier = 1 / 10;
else
    multiplier = max(1 / 10, double(horizonHours) / (5 * 2 * 7.5));
end
end

function n = localNominalWeeklyShiftCount(config)
if isfield(config, 'ValidShiftStarts') && ~isempty(config.ValidShiftStarts)
    shiftsPerDay = numel(config.ValidShiftStarts);
else
    shiftsPerDay = 2;
end
n = max(1, 5 * shiftsPerDay);
end
