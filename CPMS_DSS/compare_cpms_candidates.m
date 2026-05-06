function comparison = compare_cpms_candidates(varargin)
%COMPARE_CPMS_CANDIDATES Compare saved Digital Model candidate results.
%
%   comparison = compare_cpms_candidates()
%   comparison = compare_cpms_candidates('CampaignMode', "full")
%   comparison = compare_cpms_candidates('LatestOnly', true)
%   comparison = compare_cpms_candidates('ShowPlot', false)
%
% The function reads DSS_Output/cpms_dm_production_log.xlsx. It does not run
% Tecnomatix, does not train the GA, and does not touch the Real System.

p = inputParser;
addParameter(p, 'LogFile', "");
addParameter(p, 'CampaignMode', "");
addParameter(p, 'LatestOnly', false);
addParameter(p, 'UniqueOnly', false);
addParameter(p, 'ShowPlot', true);
addParameter(p, 'TopN', Inf);
addParameter(p, 'WriteExcel', true);
parse(p, varargin{:});
opt = p.Results;

config = cpms.resolveConfig(cpms.defaultConfig());
logFile = string(opt.LogFile);
if strlength(logFile) == 0
    logFile = string(config.DmProductionLogFile);
end

if ~isfile(logFile)
    error('compare_cpms_candidates:MissingProductionLog', ...
        'DM production log not found: %s. Run a DM scoring command first.', logFile);
end

candidateSummary = readtable(logFile, ...
    'Sheet', 'CandidateSummary', ...
    'VariableNamingRule', 'preserve');
kpiAvg = readtable(logFile, ...
    'Sheet', 'KPI_Avg', ...
    'VariableNamingRule', 'preserve');

if isempty(candidateSummary) || height(candidateSummary) == 0
    comparison = table();
    warning('compare_cpms_candidates:NoCandidates', ...
        'CandidateSummary is empty in %s.', logFile);
    return
end

candidateSummary = localNormalizeTextColumns(candidateSummary);
kpiAvg = localNormalizeTextColumns(kpiAvg);

modeFilter = lower(string(opt.CampaignMode));
if strlength(modeFilter) > 0
    candidateSummary = candidateSummary(lower(string(candidateSummary.CampaignMode)) == modeFilter, :);
end

if isempty(candidateSummary) || height(candidateSummary) == 0
    comparison = table();
    warning('compare_cpms_candidates:NoMatchingCandidates', ...
        'No saved candidates matched CampaignMode="%s".', string(opt.CampaignMode));
    return
end

if logical(opt.LatestOnly)
    candidateSummary = localLatestBatch(candidateSummary);
end

comparison = localBuildComparison(candidateSummary, kpiAvg);
if logical(opt.UniqueOnly)
    comparison = localUniqueCandidates(comparison);
end
comparison = sortrows(comparison, 'NormalizedScore', 'descend');

topN = double(opt.TopN);
if isfinite(topN) && topN > 0 && height(comparison) > topN
    comparison = comparison(1:topN, :);
end

disp(comparison);

if logical(opt.WriteExcel)
    outFile = fullfile(config.ArchiveOutputDir, 'cpms_candidate_comparison.xlsx');
    writetable(comparison, outFile);
    fprintf('Wrote %s\n', outFile);
end

if logical(opt.ShowPlot) && ~isempty(comparison)
    localPlotComparison(comparison);
end
end

function T = localNormalizeTextColumns(T)
for i = 1:numel(T.Properties.VariableNames)
    name = T.Properties.VariableNames{i};
    if iscell(T.(name)) || isstring(T.(name)) || ischar(T.(name))
        try
            T.(name) = string(T.(name));
        catch
        end
    end
end
end

function comparison = localBuildComparison(candidateSummary, kpiAvg)
n = height(candidateSummary);
candidateLabel = strings(n, 1);
producedTotal = nan(n, 1);
targetMetTotalPct = nan(n, 1);
wipProxy = nan(n, 1);
meanLeadTimeHours = nan(n, 1);
meanMachineSaturation = nan(n, 1);
maxMachineSaturation = nan(n, 1);
pt5Produced = nan(n, 1);
pt5TargetMetPct = nan(n, 1);
pt5Release = nan(n, 1);

for i = 1:n
    runId = string(candidateSummary.RunId(i));
    candidateLabel(i) = sprintf('%s C%d %s', ...
        char(string(candidateSummary.CampaignMode(i))), ...
        candidateSummary.Candidate(i), ...
        char(string(candidateSummary.Timestamp(i))));

    kpiRow = localKpiRowForRun(kpiAvg, runId);
    if ~isempty(kpiRow)
        producedTotal(i) = localNumeric(kpiRow, 'TotalProduction');
        wipProxy(i) = localNumeric(kpiRow, 'WipProxy');
        meanLeadTimeHours(i) = localNumeric(kpiRow, 'MeanLeadTimeHours');
        meanMachineSaturation(i) = localNumeric(kpiRow, 'MeanMachineSaturation');
        pt5Produced(i) = localNumeric(kpiRow, 'DailyProduction_PT5');
        sat = nan(1, 14);
        for m = 1:14
            sat(m) = localNumeric(kpiRow, "MachSat_M" + string(m));
        end
        maxMachineSaturation(i) = max(sat, [], 'omitnan');
    end

    targetTotal = localNumeric(candidateSummary(i, :), 'CampaignTargetTotal');
    if isfinite(producedTotal(i)) && targetTotal > 0
        targetMetTotalPct(i) = 100 * producedTotal(i) / targetTotal;
    end

    pt5Target = localNumeric(candidateSummary(i, :), 'CampaignTarget_PT5');
    if isfinite(pt5Produced(i)) && pt5Target > 0
        pt5TargetMetPct(i) = 100 * pt5Produced(i) / pt5Target;
    end
    pt5Release(i) = localNumeric(candidateSummary(i, :), 'Release_PT5');
end

comparison = table( ...
    candidateLabel, ...
    string(candidateSummary.RunId), ...
    candidateSummary.Timestamp, ...
    candidateSummary.Candidate, ...
    string(candidateSummary.Source), ...
    string(candidateSummary.CampaignMode), ...
    candidateSummary.Score, ...
    candidateSummary.NormalizedScore, ...
    candidateSummary.SimulatedShifts, ...
    candidateSummary.HorizonHours, ...
    candidateSummary.ReleaseRows, ...
    candidateSummary.TotalRelease, ...
    producedTotal, ...
    targetMetTotalPct, ...
    pt5Release, ...
    pt5Produced, ...
    pt5TargetMetPct, ...
    wipProxy, ...
    meanLeadTimeHours, ...
    meanMachineSaturation, ...
    maxMachineSaturation, ...
    'VariableNames', {'CandidateLabel', 'RunId', 'Timestamp', 'Candidate', ...
    'Source', 'CampaignMode', 'Score', 'NormalizedScore', 'SimulatedShifts', ...
    'HorizonHours', 'ReleaseRows', 'TotalRelease', 'ProducedTotal', ...
    'TargetMetTotalPct', 'PT5Released', 'PT5Produced', 'PT5TargetMetPct', ...
    'WipProxy', 'MeanLeadTimeHours', 'MeanMachineSaturation', ...
    'MaxMachineSaturation'});
end

function T = localLatestBatch(T)
latestRow = T(find(T.Timestamp == max(T.Timestamp), 1, 'last'), :);
sameCampaign = lower(string(T.CampaignMode)) == lower(string(latestRow.CampaignMode));
sameSource = lower(string(T.Source)) == lower(string(latestRow.Source));
sameHorizon = abs(double(T.HorizonHours) - double(latestRow.HorizonHours)) < 1e-9;
sameStart = T.StartTime == latestRow.StartTime;
sameFinish = T.FinishTime == latestRow.FinishTime;

% A full-horizon candidate can take many minutes. Keep the latest compatible
% block broad enough to include those rows, but narrow enough to avoid older
% training sessions from previous days.
recent = T.Timestamp >= latestRow.Timestamp - hours(3);
T = T(sameCampaign & sameSource & sameHorizon & sameStart & sameFinish & recent, :);
end

function T = localUniqueCandidates(T)
if isempty(T) || height(T) == 0
    return
end
keys = string(T.Source) + "|" + string(T.CampaignMode) + "|" + ...
    string(round(T.HorizonHours, 6)) + "|" + string(round(T.NormalizedScore, 6)) + "|" + ...
    string(round(T.TotalRelease, 6)) + "|" + string(round(T.ProducedTotal, 6)) + "|" + ...
    string(round(T.PT5Released, 6)) + "|" + string(round(T.PT5Produced, 6));
[~, idx] = unique(keys, 'stable');
T = T(sort(idx), :);
end

function row = localKpiRowForRun(kpiAvg, runId)
row = table();
if isempty(kpiAvg) || height(kpiAvg) == 0 || ~ismember('RunId', kpiAvg.Properties.VariableNames)
    return
end
idx = find(string(kpiAvg.RunId) == runId, 1, 'last');
if ~isempty(idx)
    row = kpiAvg(idx, :);
end
end

function value = localNumeric(T, name)
value = NaN;
name = char(name);
if ~istable(T) || ~ismember(name, T.Properties.VariableNames)
    return
end
raw = T.(name);
if isempty(raw)
    return
end
try
    value = double(raw(1));
catch
    value = str2double(string(raw(1)));
end
end

function localPlotComparison(comparison)
fig = figure('Name', 'CPMS Saved Candidate Comparison', ...
    'Tag', 'CPMSSavedCandidateComparison', 'NumberTitle', 'off');
tiledlayout(fig, 2, 2, 'Padding', 'compact', 'TileSpacing', 'compact');

labels = categorical(comparison.CandidateLabel);
labels = reordercats(labels, cellstr(comparison.CandidateLabel));

nexttile;
bar(labels, comparison.NormalizedScore);
title('Normalized Score');
ylabel('Score / simulated shift');
xtickangle(45);
grid on;

nexttile;
bar(labels, comparison.TargetMetTotalPct);
title('Total Target Met');
ylabel('%');
xtickangle(45);
grid on;

nexttile;
bar(labels, [comparison.MeanMachineSaturation, comparison.MaxMachineSaturation]);
title('Machine Saturation');
ylabel('Saturation');
legend({'Mean', 'Max'}, 'Location', 'best');
xtickangle(45);
grid on;

nexttile;
bar(labels, [comparison.PT5Released, comparison.PT5Produced]);
title('PT5 Released vs Produced');
ylabel('Parts');
legend({'Released', 'Produced'}, 'Location', 'best');
xtickangle(45);
grid on;
end
