function config = defaultConfig()
%DEFAULTCONFIG Central configuration for the CPMS Matlab DSS starter.

projectRoot = fileparts(fileparts(mfilename('fullpath')));
userRoot = getenv('USERPROFILE');
if strlength(string(userRoot)) == 0
    userRoot = char(java.lang.System.getProperty('user.home'));
end

dmDir = fullfile(userRoot, 'Documents', 'DM_student');
rsDir = fullfile(userRoot, 'MATLAB Drive', 'Cyber Physical', 'CPMS', 'RS_group8');
if ~isfolder(dmDir)
    dmDir = projectRoot;
end
if ~isfolder(rsDir)
    rsDir = '';
end

config = struct();
config.ProjectRoot = projectRoot;
config.DmDir = dmDir;
config.RsDir = rsDir;

% Safe default: work against the Digital Model folder and first-week logs.
% The real-system folder is detected but never executed by this package.
config.RsInputDir = dmDir;
config.RsOutputDir = dmDir;
config.LogDir = fullfile(dmDir, 'RS_FirstWeekData');
config.DecisionOutputDir = dmDir;
config.ArchiveOutputDir = fullfile(projectRoot, 'DSS_Output');

% File discovery.
config.SysStatePattern = '*SysState*.xlsx';
config.ReleaseTablePattern = '*ReleaseTable*.xlsx';
config.RoutingTablePattern = '*RoutingTable*.xlsx';
config.CycleTimeTablePattern = '*CycleTimeTable*.xlsx';
config.LogPatterns = {'*.csv', '*.xlsx'};

% Course scenario values extracted from the supplied controllers and files.
config.ShiftId = [];
config.ShiftStart = [];
config.ShiftLengthHours = 7.5;
config.ReleaseSpacingMinutes = 12;
config.CourseHolidays = dateshift(datetime([2025 12 8; 2025 12 25; 2025 12 26]), 'start', 'day');
config.ValidShiftStarts = [duration(6, 30, 0), duration(14, 30, 0)];
config.ValidShiftEnds = [duration(14, 0, 0), duration(22, 0, 0)];
config.ProductTypes = {'PT1', 'PT2', 'PT3', 'PT4', 'PT5'};
config.TargetByPart = table( ...
    string(config.ProductTypes(:)), ...
    [100; 200; 180; 200; 150], ...
    'VariableNames', {'PartType', 'TargetQty'});
config.MaxReleasePerPart = [163; 137; 125; 112; 164];
config.MinLot = 5;
config.WipTarget = 150;

% DM/GA scoring weights. PT5 is intentionally weighted higher because the
% current trained policy underproduces it in full-horizon rehearsals.
config.ScorePartWeights = [1.0, 1.0, 1.0, 1.0, 1.45];
config.ReleasePriorityByPart = [1.0, 1.0, 1.0, 1.0, 1.18];
config.CampaignReleasePressureMin = 0.60;
config.CampaignReleasePressureMax = 1.25;
config.ShiftReleasePressureMin = 0.75;
config.ShiftReleasePressureMax = 1.15;
config.ScoreSaturationTarget = 0.85;
config.ScoreSaturationHardLimit = 0.95;
config.ScoreSaturationSpreadWeight = 20.0;
config.ScoreMeanSaturationWeight = 35.0;
config.ScoreHighSaturationWeight = 450.0;
config.ScoreHardSaturationWeight = 1500.0;
config.ScoreMinTotalTargetPct = 0.85;
config.ScoreMinPartTargetPct = 0.72;
config.ScoreMinPT5TargetPct = 0.85;
config.ScorePlanEffWeight = 250.0;
config.ScorePlanEffShortfallWeight = 550.0;
config.ScoreExcessReleaseWeight = 1.0;
config.ScoreTotalTargetShortfallWeight = 900.0;
config.ScorePartTargetShortfallWeight = 350.0;
config.ScorePT5TargetShortfallWeight = 900.0;
config.ScoreWipOverTargetWeight = 2.0;
config.ScoreUseRobustReplicateScore = true;
config.ScoreReplicateStdWeight = 0.50;
config.ScoreAggregateBlend = 0.25;

% CPMS fixed routing stages.
config.Machines = "M" + string(1:14);
config.StageMachineGroups = {1:3, 4:7, 8:10, 11:14};
config.SkipStage3Parts = ["PT1", "PT5"];

% Optional digital-model scoring. Disabled by default so run_cpms_shift()
% inspects and writes files without launching Tecnomatix. Enable explicitly
% with 'UseDigitalModelScoring', true once the DM folder is ready.
config.UseDigitalModelScoring = false;
config.DmHorizonHours = 8;
config.DmWorkDir = fullfile(projectRoot, 'DSS_Output', 'DM_Work');
% Tecnomatix model behavior is path-sensitive: the copied DM_Work model can
% validate inputs yet produce candidate-invariant scores. Run the official
% course model in its native DM_student folder for scoring.
config.UseDmWorkingCopy = false;
config.ConfigureDigitalModelBeforeRun = true;
% The p-coded course runner is the authoritative DM execution path. The
% custom live COM runner is kept available for diagnostics, but it does not
% reproduce all hidden dm_config side effects reliably enough for GA scoring.
config.UseLiveDigitalModelRunner = false;
config.ReloadExcelInputsInLiveRunner = true;
% With the trusted p-coded dm_run path, this shows a post-campaign dashboard
% from the returned DM tables. True mid-run plotting is available only through
% the diagnostic live runner.
config.EnableLiveDashboard = true;
config.ReuseLiveDashboard = true;
config.DashboardUpdateGranularity = "campaign";
config.LivePollSeconds = 2;
config.LivePollMetricsDuringRun = false;
config.ProgressPrintSeconds = 30;
config.MaxReplicationRuntimeSeconds = 1800;
config.ReloadModelEachReplication = true;
config.SaveDigitalModelAfterRun = false;
config.DmReplications = 8;
config.UseCommonRandomNumbers = true;
config.DmSeedVector = mod(1009 + 7919 * (0:63), 9999) + 1;
config.DmRunMatlabRngSeed = 271828;
config.FailOnCollapsedCandidateScores = true;
config.FailOnCollapsedReleaseOnlyScores = false;
config.CollapsedScoreTolerance = 1e-9;
config.TrainingCampaignMode = "weekly";
config.TrainingCampaignWeeks = 1;
config.FullHorizonEvaluationMode = "weeklyAggregate";
config.ProjectEndTime = datetime(2025, 12, 26, 14, 30, 0);
config.NumReleaseCandidates = 5;
config.UsePersistentGaTraining = true;
config.GaStateVersion = 8;
config.UseTrainedGaPolicyOnly = false;
config.ScoreTrainedGaPolicy = false;
config.TrainedPolicyMode = "weekly";
config.TrainedPolicyStateFile = "";
config.TrainingStateFile = "";
config.TrainingHistoryFile = "";
config.DmProductionLogFile = fullfile(projectRoot, 'DSS_Output', 'cpms_dm_production_log.xlsx');
config.GaPopulationSize = 12;
config.GaEliteCount = 3;
config.GaMutationRelease = 12;
config.GaMutationRouting = 12;
config.GaRandomImmigrantFraction = 0.25;
config.GaRandomSeed = [];
config.GaDuplicateRetryLimit = 100;
config.BackupExistingDecisionFiles = true;
config.QuarantineUnsafeInputs = true;
config.QuarantineDir = fullfile(projectRoot, 'DSS_Output', 'quarantine');

% Import behavior.
config.PreserveVariableNames = true;
config.Verbose = true;
end
