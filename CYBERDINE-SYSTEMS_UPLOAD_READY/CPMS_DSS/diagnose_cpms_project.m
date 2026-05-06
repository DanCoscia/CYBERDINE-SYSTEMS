function report = diagnose_cpms_project(varargin)
%DIAGNOSE_CPMS_PROJECT Check CPMS DSS readiness without running RS or DM.
%
%   REPORT = DIAGNOSE_CPMS_PROJECT() inspects the active Excel files,
%   generated DM/GA logs, and saved training state. It does not launch
%   Tecnomatix and never calls the Real System.

config = cpms.defaultConfig();
if nargin == 1 && isstruct(varargin{1})
    config = cpms.mergeStruct(config, varargin{1});
elseif nargin > 0
    if mod(nargin, 2) ~= 0
        error('diagnose_cpms_project:InvalidArguments', ...
            'Use either a config struct or name/value pairs.');
    end
    config = cpms.mergeStruct(config, struct(varargin{:}));
end
config = cpms.resolveConfig(config);

issues = table(strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), ...
    'VariableNames', {'Severity', 'Area', 'Message', 'Recommendation'});
summary = struct();
summary.ProjectRoot = string(config.ProjectRoot);
summary.DmDir = string(config.DmDir);
summary.DecisionOutputDir = string(config.DecisionOutputDir);
summary.DmWorkDir = string(config.DmWorkDir);
summary.RealSystemExecuted = false;
summary.DigitalModelExecuted = false;

[releaseSummary, releaseIssues] = localCheckReleaseTable(config);
[routingSummary, routingIssues] = localCheckRoutingTable(config);
[cycleSummary, cycleIssues] = localCheckCycleTimeTable(config);
[sysStateSummary, sysStateIssues] = localCheckSysState(config);
[trainingSummary, trainingIssues] = localCheckTrainingState(config);
[logSummary, logIssues] = localCheckProductionLog(config);

issues = cpms.vertcatLoose(issues, releaseIssues);
issues = cpms.vertcatLoose(issues, routingIssues);
issues = cpms.vertcatLoose(issues, cycleIssues);
issues = cpms.vertcatLoose(issues, sysStateIssues);
issues = cpms.vertcatLoose(issues, trainingIssues);
issues = cpms.vertcatLoose(issues, logIssues);

blocking = any(issues.Severity == "ERROR");
warnings = sum(issues.Severity == "WARN");
if blocking
    readiness = "not ready";
elseif warnings > 0
    readiness = "usable with warnings";
else
    readiness = "ready for DM rehearsal / manual RS handoff";
end

summary.Readiness = readiness;
summary.ErrorCount = sum(issues.Severity == "ERROR");
summary.WarningCount = warnings;

report = struct();
report.Summary = summary;
report.ReleaseTable = releaseSummary;
report.RoutingTable = routingSummary;
report.CycleTimeTable = cycleSummary;
report.SysState = sysStateSummary;
report.TrainingState = trainingSummary;
report.ProductionLog = logSummary;
report.Issues = issues;

localPrintReport(report);
end

function [summary, issues] = localCheckReleaseTable(config)
path = fullfile(config.DecisionOutputDir, 'ReleaseTable.xlsx');
summary = struct('Path', string(path), 'Exists', isfile(path), ...
    'Rows', 0, 'TotalRelease', 0, 'TotalsByPart', zeros(1, 5), ...
    'FirstRelease', NaT, 'LastRelease', NaT);
issues = localIssueTable();
if ~summary.Exists
    issues = localAddIssue(issues, "ERROR", "ReleaseTable", ...
        "ReleaseTable.xlsx was not found.", ...
        "Run run_cpms_trained_policy() or run_cpms_shift().");
    return
end

try
    T = readtable(path, 'VariableNamingRule', 'preserve', 'DatetimeType', 'datetime');
catch err
    issues = localAddIssue(issues, "ERROR", "ReleaseTable", ...
        "ReleaseTable.xlsx could not be read: " + string(err.message), ...
        "Close Excel/Plant Simulation and regenerate the table.");
    return
end

required = ["Release Time", "Part Type", "Number"];
if ~all(ismember(required, string(T.Properties.VariableNames)))
    issues = localAddIssue(issues, "ERROR", "ReleaseTable", ...
        "ReleaseTable.xlsx is missing required columns.", ...
        "Expected exactly Release Time, Part Type, Number.");
    return
end

summary.Rows = height(T);
qty = double(T.Number);
pt = string(T.("Part Type"));
times = T.("Release Time");
if ~isdatetime(times)
    times = datetime(times);
end
summary.TotalRelease = sum(qty, 'omitnan');
for i = 1:5
    summary.TotalsByPart(i) = sum(qty(pt == "PT" + string(i)), 'omitnan');
end
if ~isempty(times)
    summary.FirstRelease = min(times);
    summary.LastRelease = max(times);
end

if any(qty <= 0 | ~isfinite(qty))
    issues = localAddIssue(issues, "ERROR", "ReleaseTable", ...
        "Release quantities contain zero, negative, or nonfinite values.", ...
        "Regenerate the release table before using it.");
end
badPart = ~ismember(pt, "PT" + string(1:5));
if any(badPart)
    issues = localAddIssue(issues, "ERROR", "ReleaseTable", ...
        sprintf('Release table contains %d invalid part-type rows.', nnz(badPart)), ...
        "Allowed part types are PT1 through PT5.");
end

[badCalendar, badWindow] = localBadReleaseTimes(times, config);
if any(badCalendar)
    issues = localAddIssue(issues, "ERROR", "ReleaseTable", ...
        sprintf('Release table contains %d weekend/holiday rows.', nnz(badCalendar)), ...
        "Remove releases on weekends and course holidays.");
end
if any(badWindow)
    issues = localAddIssue(issues, "ERROR", "ReleaseTable", ...
        sprintf('Release table contains %d rows outside valid shift windows.', nnz(badWindow)), ...
        "Release times must be inside 06:30-14:00 or 14:30-22:00.");
end

targets = localTargetVector(config);
if all(isfinite(targets)) && summary.TotalRelease > 8 * sum(targets)
    issues = localAddIssue(issues, "WARN", "ReleaseTable", ...
        sprintf('Total release %.0f is much larger than one weekly target %.0f.', ...
        summary.TotalRelease, sum(targets)), ...
        "Confirm this is a full-horizon plan, not a single-shift RS handoff.");
end
end

function [summary, issues] = localCheckRoutingTable(config)
path = fullfile(config.DecisionOutputDir, 'RoutingTable.xlsx');
summary = struct('Path', string(path), 'Exists', isfile(path), ...
    'Rows', 0, 'StageSumsOk', false, 'ForbiddenStage3Ok', false);
issues = localIssueTable();
if ~summary.Exists
    issues = localAddIssue(issues, "ERROR", "RoutingTable", ...
        "RoutingTable.xlsx was not found.", ...
        "Run run_cpms_trained_policy() or run_cpms_shift().");
    return
end

try
    T = readtable(path, 'VariableNamingRule', 'preserve');
catch err
    issues = localAddIssue(issues, "ERROR", "RoutingTable", ...
        "RoutingTable.xlsx could not be read: " + string(err.message), ...
        "Close Excel/Plant Simulation and regenerate the table.");
    return
end

summary.Rows = height(T);
vars = string(T.Properties.VariableNames);
if ~ismember("PT", vars) || ~all(ismember("M" + string(1:14), vars))
    issues = localAddIssue(issues, "ERROR", "RoutingTable", ...
        "Routing table must contain PT and M1-M14 columns.", ...
        "Regenerate the routing table.");
    return
end

R = table2array(T(:, cellstr("M" + string(1:14))));
pt = string(T.PT);
tolerance = 1e-6;
stageOk = true;
for r = 1:height(T)
    for s = 1:numel(config.StageMachineGroups)
        cols = config.StageMachineGroups{s};
        stageSum = sum(R(r, cols), 'omitnan');
        if s == 3 && ismember(pt(r), config.SkipStage3Parts)
            if abs(stageSum) > tolerance
                stageOk = false;
            end
        elseif abs(stageSum - 100) > 1e-3
            stageOk = false;
        end
    end
end
summary.StageSumsOk = stageOk;
summary.ForbiddenStage3Ok = all(abs(sum(R(ismember(pt, config.SkipStage3Parts), 8:10), 2)) <= tolerance);
if ~stageOk
    issues = localAddIssue(issues, "ERROR", "RoutingTable", ...
        "Routing percentages do not sum correctly by stage/part.", ...
        "Regenerate routing or inspect M1-M14 percentages.");
end
if any(R < -tolerance | R > 100 + tolerance, 'all')
    issues = localAddIssue(issues, "ERROR", "RoutingTable", ...
        "Routing table contains percentages outside 0-100.", ...
        "Regenerate routing before handoff.");
end
end

function [summary, issues] = localCheckCycleTimeTable(config)
path = fullfile(config.DecisionOutputDir, 'CycleTimeTable.xlsx');
summary = struct('Path', string(path), 'Exists', isfile(path), ...
    'Rows', 0, 'MinNonzeroSeconds', NaN, 'MaxSeconds', NaN, ...
    'ForbiddenZerosOk', false);
issues = localIssueTable();
if ~summary.Exists
    issues = localAddIssue(issues, "ERROR", "CycleTimeTable", ...
        "CycleTimeTable.xlsx was not found.", ...
        "Run run_cpms_shift() to estimate/write cycle times.");
    return
end

try
    T = readtable(path, 'VariableNamingRule', 'preserve');
catch err
    issues = localAddIssue(issues, "ERROR", "CycleTimeTable", ...
        "CycleTimeTable.xlsx could not be read: " + string(err.message), ...
        "Close Excel/Plant Simulation and regenerate the table.");
    return
end

summary.Rows = height(T);
needed = ["M", "PT1", "PT2", "PT3", "PT4", "PT5"];
if ~all(ismember(needed, string(T.Properties.VariableNames)))
    issues = localAddIssue(issues, "ERROR", "CycleTimeTable", ...
        "CycleTime table must contain M and PT1-PT5 columns.", ...
        "Regenerate cycle times.");
    return
end

values = table2array(T(:, cellstr("PT" + string(1:5))));
if any(~isfinite(values), 'all')
    issues = localAddIssue(issues, "ERROR", "CycleTimeTable", ...
        "CycleTime table contains NaN or Inf values.", ...
        "Regenerate cycle times or use defaults for missing cells.");
end
nonzero = values(values > 0 & isfinite(values));
if ~isempty(nonzero)
    summary.MinNonzeroSeconds = min(nonzero);
    summary.MaxSeconds = max(nonzero);
end

machines = string(T.M);
stage3 = ismember(machines, ["M8", "M9", "M10"]);
forbidden = [T.PT1(stage3); T.PT5(stage3)];
summary.ForbiddenZerosOk = all(forbidden == 0);
if ~summary.ForbiddenZerosOk
    issues = localAddIssue(issues, "ERROR", "CycleTimeTable", ...
        "PT1/PT5 stage-3 cycle times must remain zero.", ...
        "Restore zeros for M8-M10 PT1/PT5.");
end
end

function [summary, issues] = localCheckSysState(config)
path = fullfile(config.DmDir, 'SysState.xlsx');
if isfield(config, 'UseDmWorkingCopy') && config.UseDmWorkingCopy && ...
        isfield(config, 'DmWorkDir') && isfile(fullfile(config.DmWorkDir, 'SysState.xlsx'))
    path = fullfile(config.DmWorkDir, 'SysState.xlsx');
end
summary = struct('Path', string(path), 'Exists', isfile(path), ...
    'Rows', 0, 'WIP', NaN, 'WIPByPart', zeros(1, 5));
issues = localIssueTable();
if ~summary.Exists
    issues = localAddIssue(issues, "WARN", "SysState", ...
        "SysState.xlsx was not found in the configured Digital Model folder.", ...
        "DM scoring needs SysState.xlsx before running.");
    return
end
try
    T = readtable(path, 'VariableNamingRule', 'preserve');
catch err
    issues = localAddIssue(issues, "WARN", "SysState", ...
        "SysState.xlsx could not be read: " + string(err.message), ...
        "Close Excel/Plant Simulation and try again.");
    return
end
summary.Rows = height(T);
try
    wip = cpms.computeWip(struct('Primary', T, 'File', path), config);
    summary.WIP = wip.Total;
    if isfield(wip, 'ByPart') && istable(wip.ByPart)
        for i = 1:5
            idx = find(string(wip.ByPart.PartType) == "PT" + string(i), 1);
            if ~isempty(idx)
                summary.WIPByPart(i) = wip.ByPart.WIP(idx);
            end
        end
    end
catch
    summary.WIP = height(T);
end
end

function [summary, issues] = localCheckTrainingState(config)
summary = struct('Path', string(config.TrainingStateFile), ...
    'Exists', isfile(config.TrainingStateFile), 'Generation', 0, ...
    'BestNormalizedScore', NaN, 'Version', NaN);
issues = localIssueTable();
if ~summary.Exists
    issues = localAddIssue(issues, "WARN", "TrainingState", ...
        "No saved GA training state exists for the current campaign mode.", ...
        "Run weekly DM training before using a trained policy.");
    return
end
try
    S = load(config.TrainingStateFile, 'trainingState');
    ts = S.trainingState;
    if isfield(ts, 'Version'), summary.Version = ts.Version; end
    if isfield(ts, 'Generation'), summary.Generation = ts.Generation; end
    if isfield(ts, 'BestNormalizedScore'), summary.BestNormalizedScore = ts.BestNormalizedScore; end
    if isfield(config, 'GaStateVersion') && isfinite(summary.Version) && ...
            summary.Version ~= round(double(config.GaStateVersion(1)))
        issues = localAddIssue(issues, "WARN", "TrainingState", ...
            sprintf('Saved GA state version %.0f is stale; current code expects %.0f.', ...
            summary.Version, round(double(config.GaStateVersion(1)))), ...
            "The next training run will ignore this stale state and start fresh.");
    end
catch err
    issues = localAddIssue(issues, "WARN", "TrainingState", ...
        "Saved training state could not be loaded: " + string(err.message), ...
        "Reset GA state and train again.");
end
end

function [summary, issues] = localCheckProductionLog(config)
path = config.DmProductionLogFile;
summary = struct('Path', string(path), 'Exists', isfile(path), ...
    'LastCandidateCount', 0, 'LastScoresCollapsed', false, ...
    'LastRunBestNormalizedScore', NaN);
issues = localIssueTable();
if ~summary.Exists
    issues = localAddIssue(issues, "WARN", "ProductionLog", ...
        "No DM production log exists yet.", ...
        "Run DM scoring before judging trained-policy quality.");
    return
end

try
    C = readtable(path, 'Sheet', 'CandidateSummary', ...
        'VariableNamingRule', 'preserve', 'TextType', 'string');
catch err
    issues = localAddIssue(issues, "WARN", "ProductionLog", ...
        "CandidateSummary could not be read: " + string(err.message), ...
        "Recreate the production log with a fresh DM scoring run.");
    return
end

block = localLastCandidateBlock(C);
summary.LastCandidateCount = height(block);
if isempty(block) || height(block) == 0
    return
end
if ismember('NormalizedScore', block.Properties.VariableNames)
    scores = double(block.NormalizedScore);
    summary.LastRunBestNormalizedScore = max(scores, [], 'omitnan');
    if numel(scores) > 1
        scoreSpan = max(scores) - min(scores);
        releaseCols = ["Release_PT1", "Release_PT2", "Release_PT3", "Release_PT4", "Release_PT5"];
        releasesDiffer = all(ismember(releaseCols, string(block.Properties.VariableNames))) && ...
            size(unique(block{:, cellstr(releaseCols)}, 'rows'), 1) > 1;
        summary.LastScoresCollapsed = releasesDiffer && abs(scoreSpan) <= 1e-9 * max(1, abs(scores(1)));
        if summary.LastScoresCollapsed
            routingDiffers = localLatestRoutingDiffers(path, block);
            if routingDiffers
                issues = localAddIssue(issues, "ERROR", "ProductionLog", ...
                    "The latest DM scoring block gave identical scores to different routing plans.", ...
                    "Discard that generation; the DM probably did not reload candidate inputs.");
            else
                issues = localAddIssue(issues, "WARN", "ProductionLog", ...
                    "The latest DM scoring block gave identical scores to different release plans.", ...
                    "This may be capacity saturation. Use wider release-pressure settings or inspect RoutingPlan.");
            end
        end
    end
end
end

function tf = localLatestRoutingDiffers(logPath, candidateBlock)
tf = false;
if isempty(candidateBlock) || height(candidateBlock) == 0 || ...
        ~ismember('RunId', candidateBlock.Properties.VariableNames)
    return
end
try
    R = readtable(logPath, 'Sheet', 'RoutingPlan', ...
        'VariableNamingRule', 'preserve', 'TextType', 'string');
catch
    return
end
machineCols = "M" + string(1:14);
if isempty(R) || ~all(ismember(["RunId", "PT", machineCols], string(R.Properties.VariableNames)))
    return
end
runIds = string(candidateBlock.RunId);
signatures = strings(numel(runIds), 1);
for i = 1:numel(runIds)
    rows = R(string(R.RunId) == runIds(i), :);
    if isempty(rows) || height(rows) == 0
        continue
    end
    rows = sortrows(rows, 'PT');
    values = rows{:, cellstr(machineCols)};
    values(~isfinite(values)) = -999999;
    signatures(i) = string(sprintf('%.3f,', values(:)));
end
signatures = signatures(strlength(signatures) > 0);
tf = numel(unique(signatures)) > 1;
end

function block = localLastCandidateBlock(C)
block = C([], :);
if isempty(C) || height(C) == 0 || ~ismember('Candidate', C.Properties.VariableNames)
    return
end
cand = double(C.Candidate);
startIdx = height(C);
while startIdx > 1 && cand(startIdx - 1) < cand(startIdx)
    startIdx = startIdx - 1;
end
block = C(startIdx:height(C), :);
end

function [badCalendar, badWindow] = localBadReleaseTimes(times, config)
badCalendar = false(size(times));
badWindow = false(size(times));
if isempty(times)
    return
end
releaseDates = dateshift(times, 'start', 'day');
holidays = dateshift(config.CourseHolidays(:), 'start', 'day');
badCalendar = ismember(weekday(releaseDates), [1 7]) | ismember(releaseDates, holidays);
tod = timeofday(times);
inMorning = tod >= duration(6,30,0) & tod < duration(14,0,0);
inAfternoon = tod >= duration(14,30,0) & tod < duration(22,0,0);
badWindow = ~(inMorning | inAfternoon);
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

function issues = localIssueTable()
issues = table(strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), ...
    'VariableNames', {'Severity', 'Area', 'Message', 'Recommendation'});
end

function issues = localAddIssue(issues, severity, area, message, recommendation)
row = table(string(severity), string(area), string(message), string(recommendation), ...
    'VariableNames', {'Severity', 'Area', 'Message', 'Recommendation'});
issues = cpms.vertcatLoose(issues, row);
end

function localPrintReport(report)
fprintf('\nCPMS DSS diagnostic summary\n');
fprintf('  Readiness: %s\n', report.Summary.Readiness);
fprintf('  Errors: %d, warnings: %d\n', report.Summary.ErrorCount, report.Summary.WarningCount);
fprintf('  Real System executed by diagnostic: false\n');
fprintf('  Digital Model executed by diagnostic: false\n');
fprintf('\nRelease table: %d rows, total release %.0f\n', ...
    report.ReleaseTable.Rows, report.ReleaseTable.TotalRelease);
fprintf('Routing table stage sums ok: %d\n', report.RoutingTable.StageSumsOk);
fprintf('Cycle-time forbidden zeros ok: %d\n', report.CycleTimeTable.ForbiddenZerosOk);
fprintf('Training state exists: %d, generation: %d, best normalized score: %.3f\n', ...
    report.TrainingState.Exists, report.TrainingState.Generation, ...
    report.TrainingState.BestNormalizedScore);
fprintf('Production log exists: %d, latest candidate count: %d, collapsed latest scores: %d\n', ...
    report.ProductionLog.Exists, report.ProductionLog.LastCandidateCount, ...
    report.ProductionLog.LastScoresCollapsed);

if ~isempty(report.Issues) && height(report.Issues) > 0
    fprintf('\nIssues:\n');
    for i = 1:height(report.Issues)
        fprintf('  [%s] %s: %s\n      %s\n', ...
            report.Issues.Severity(i), report.Issues.Area(i), ...
            report.Issues.Message(i), report.Issues.Recommendation(i));
    end
else
    fprintf('\nNo issues found by safe diagnostic checks.\n');
end
fprintf('\n');
end
