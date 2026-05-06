function fig = plotDigitalModelDashboard(dmResult, plan, candidateIndex, score, normalizedScore, campaignInfo, config)
%PLOTDIGITALMODELDASHBOARD Plot trusted dm_run outputs after a campaign.
%
% This dashboard is intentionally post-campaign, not mid-replication. It uses
% the official p-coded dm_run return struct, so it can stay on the trusted DM
% scoring path while still giving visual feedback.

if nargin < 7
    config = struct();
end

if isfield(config, 'ReuseLiveDashboard') && config.ReuseLiveDashboard
    fig = findobj(0, 'Type', 'figure', 'Tag', 'CPMSOfficialDmDashboard');
    if isempty(fig)
        fig = figure('Name', 'CPMS DM KPI Dashboard', ...
            'Tag', 'CPMSOfficialDmDashboard', 'NumberTitle', 'off');
    else
        fig = fig(1);
        figure(fig);
        clf(fig);
    end
else
    fig = figure('Name', 'CPMS DM KPI Dashboard', ...
        'Tag', 'CPMSOfficialDmDashboard', 'NumberTitle', 'off');
end

[thAvg, hasTh] = localAverageMatrix(dmResult, 'ThPerShift');
[dailyAvg, hasDaily] = localAverageMatrix(dmResult, 'DailyCumProd');
[satAvg, hasSat] = localAverageMatrix(dmResult, 'MachSat');
[buffAvg, hasBuff] = localAverageMatrix(dmResult, 'AvgBuffLevel');

ptNames = {'PT1', 'PT2', 'PT3', 'PT4', 'PT5'};
machineNames = "M" + string(1:14);

sgtitle(sprintf('Digital Model KPIs - candidate %d %s - score %.3f / norm %.3f', ...
    candidateIndex, char(string(localStructValue(campaignInfo, 'CampaignMode', ""))), ...
    score, normalizedScore), 'Interpreter', 'none');

subplot(2, 3, 1);
if hasTh && ~isempty(thAvg)
    localPlotPtLines(gca, thAvg, ptNames);
    xlabel('Shift');
    ylabel('TH\_SHIFT rate');
else
    localNoData(gca, 'No TH_SHIFT data');
end
title('Shift Throughput by PT (TH\_SHIFT)', 'Interpreter', 'none');

subplot(2, 3, 2);
[dailyForPlot, dayLabel] = localDailyProductionForPlot(thAvg, hasTh, dailyAvg, hasDaily, campaignInfo, config);
if ~isempty(dailyForPlot)
    localPlotPtLines(gca, cumsum(dailyForPlot, 1), ptNames);
    xlabel(dayLabel);
    ylabel('Parts');
else
    localNoData(gca, 'No daily production data');
end
title('Cumulative Production by PT', 'Interpreter', 'none');

subplot(2, 3, 3);
totals = localProductionTotals(thAvg, hasTh, dailyAvg, hasDaily, campaignInfo, config);
target = localCampaignTarget(campaignInfo, config);
if any(isfinite(totals)) && any(target > 0)
    attainment = 100 * totals ./ max(target, eps);
    bar(categorical(ptNames), attainment);
    ylim([0, max(100, ceil(max(attainment, [], 'omitnan') / 10) * 10)]);
    ylabel('Target met (%)');
else
    localNoData(gca, 'No target/production data');
end
title('Campaign Target Attainment', 'Interpreter', 'none');

subplot(2, 3, 4);
if hasBuff && ~isempty(buffAvg)
    values = localVector14(buffAvg);
    plot(1:numel(values), values, '-o', 'LineWidth', 1.5);
    xlim([1 numel(values)]);
    xticks(1:numel(values));
    xticklabels(machineNames);
    xtickangle(45);
    ylabel('Avg buffer level');
else
    localNoData(gca, 'No AvgBuffLevel data');
end
title('WIP Proxy by Machine', 'Interpreter', 'none');

subplot(2, 3, 5);
if hasSat && ~isempty(satAvg)
    values = localVector14(satAvg);
    bar(categorical(cellstr(machineNames)), values);
    ylim([0, max(1, ceil(max(values, [], 'omitnan') * 10) / 10)]);
    ylabel('Saturation');
else
    localNoData(gca, 'No MachSat data');
end
title('Machine Saturation', 'Interpreter', 'none');

subplot(2, 3, 6);
if ~localPlotCandidateComparison(gca, campaignInfo, config)
    releaseTotals = localReleaseTotals(plan);
    if any(isfinite(totals)) || any(releaseTotals > 0)
        bar(categorical(ptNames), [releaseTotals(:), totals(:)]);
        legend({'Released', 'Produced'}, 'Location', 'best');
        ylabel('Parts');
    else
        localNoData(gca, 'No release/production data');
    end
    title('Release vs Produced', 'Interpreter', 'none');
end

drawnow;
end

function localPlotPtLines(ax, M, ptNames)
M = double(M);
cols = min(5, size(M, 2));
plot(ax, 1:size(M, 1), M(:, 1:cols), 'LineWidth', 1.5);
grid(ax, 'on');
legend(ax, ptNames(1:cols), 'Location', 'best');
end

function localNoData(ax, message)
cla(ax);
axis(ax, 'off');
text(ax, 0.5, 0.5, message, 'HorizontalAlignment', 'center');
end

function [M, label] = localDailyProductionForPlot(thAvg, hasTh, dailyAvg, hasDaily, campaignInfo, config)
M = [];
label = 'Production day';
if hasTh && ~isempty(thAvg)
    [fromShift, ok] = localDailyFromShift(thAvg, campaignInfo, config);
    if ok
        M = fromShift;
        return
    end
end
if hasDaily && ~isempty(dailyAvg)
    M = localFiveCols(dailyAvg);
    label = 'DM period';
end
end

function [daily, ok] = localDailyFromShift(thAvg, campaignInfo, config)
daily = [];
ok = false;
if isempty(thAvg)
    return
end
shiftTimes = [];
if isfield(campaignInfo, 'ProductionShiftTimes')
    shiftTimes = campaignInfo.ProductionShiftTimes;
end
if isempty(shiftTimes) || numel(shiftTimes) < size(thAvg, 1)
    return
end
shiftTimes = shiftTimes(1:size(thAvg, 1));
shiftDays = dateshift(shiftTimes(:), 'start', 'day');
[group, days] = findgroups(shiftDays);
daily = zeros(numel(days), 5);
shiftLength = localShiftLength(campaignInfo, config);
M = localFiveCols(thAvg) * shiftLength;
for p = 1:5
    daily(:, p) = splitapply(@(x) sum(x, 'omitnan'), M(:, p), group);
end
ok = true;
end

function totals = localProductionTotals(thAvg, hasTh, dailyAvg, hasDaily, campaignInfo, config)
totals = nan(1, 5);
if hasDaily && ~isempty(dailyAvg)
    M = localFiveCols(dailyAvg);
    totals = sum(M, 1, 'omitnan');
    return
end
if hasTh && ~isempty(thAvg)
    M = localFiveCols(thAvg) * localShiftLength(campaignInfo, config);
    totals = sum(M, 1, 'omitnan');
end
end

function target = localCampaignTarget(campaignInfo, config)
target = nan(1, 5);
if isfield(campaignInfo, 'CampaignTarget') && ~isempty(campaignInfo.CampaignTarget)
    values = double(campaignInfo.CampaignTarget(:))';
    target(1:min(5, numel(values))) = values(1:min(5, numel(values)));
    return
end
if isfield(config, 'TargetByPart') && istable(config.TargetByPart) && ...
        ismember('TargetQty', config.TargetByPart.Properties.VariableNames)
    values = double(config.TargetByPart.TargetQty(:))';
    target(1:min(5, numel(values))) = values(1:min(5, numel(values)));
end
end

function releaseTotals = localReleaseTotals(plan)
releaseTotals = zeros(1, 5);
if ~isstruct(plan) || ~isfield(plan, 'ReleaseTable') || isempty(plan.ReleaseTable)
    return
end
T = plan.ReleaseTable;
if ~all(ismember({'Part Type', 'Number'}, T.Properties.VariableNames))
    return
end
partTypes = string(T.("Part Type"));
numbers = double(T.Number);
for p = 1:5
    releaseTotals(p) = sum(numbers(partTypes == "PT" + string(p)), 'omitnan');
end
end

function plotted = localPlotCandidateComparison(ax, campaignInfo, config)
plotted = false;
if ~isfield(config, 'DmProductionLogFile') || ~isfile(config.DmProductionLogFile)
    return
end

try
    candidateSummary = readtable(config.DmProductionLogFile, ...
        'Sheet', 'CandidateSummary', 'VariableNamingRule', 'preserve');
    kpiAvg = readtable(config.DmProductionLogFile, ...
        'Sheet', 'KPI_Avg', 'VariableNamingRule', 'preserve');
catch
    return
end

candidateSummary = localNormalizeTextColumns(candidateSummary);
kpiAvg = localNormalizeTextColumns(kpiAvg);
candidateBlock = localLatestCandidateBlock(candidateSummary, campaignInfo, config);
summary = localCandidateSummaryFromLog(candidateBlock, kpiAvg);
if isempty(summary) || height(summary) == 0
    return
end

metricMatrix = [summary.TargetMetPct, summary.WipRel, summary.LeadRel];
if all(~isfinite(metricMatrix(:)))
    return
end

cla(ax);
bars = bar(ax, metricMatrix, 'grouped');
grid(ax, 'on');
labels = "C" + string(summary.Candidate) + newline + ...
    "S " + string(round(summary.NormalizedScore, 1));
set(ax, 'XTick', 1:height(summary), 'XTickLabel', labels);
ylabel(ax, 'Normalized metric');
title(ax, 'Candidate Comparison', 'Interpreter', 'none');
legendLabels = {'Target met %', 'WIP rel.', 'Lead rel.'};
n = min(numel(bars), numel(legendLabels));
if n > 0
    legend(ax, bars(1:n), legendLabels(1:n), 'Location', 'best');
end
finiteValues = metricMatrix(isfinite(metricMatrix));
if ~isempty(finiteValues)
    ylim(ax, [min(0, floor(min(finiteValues) / 10) * 10), ...
        max(100, ceil(max(finiteValues) / 10) * 10)]);
end
plotted = true;
end

function T = localNormalizeTextColumns(T)
if isempty(T) || ~istable(T)
    return
end
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

function block = localLatestCandidateBlock(candidateSummary, campaignInfo, config)
block = table();
if isempty(candidateSummary) || height(candidateSummary) == 0 || ...
        ~ismember('Candidate', candidateSummary.Properties.VariableNames)
    return
end

mask = true(height(candidateSummary), 1);
mode = string(localStructValue(campaignInfo, 'CampaignMode', ""));
if strlength(mode) > 0 && ismember('CampaignMode', candidateSummary.Properties.VariableNames)
    modeValues = lower(string(candidateSummary.CampaignMode));
    modeMask = modeValues == lower(mode);
    if ~any(modeMask) && contains(lower(mode), "full-week-")
        modeMask = modeValues == "full";
    end
    if any(modeMask)
        mask = mask & modeMask;
    end
end

if isfield(campaignInfo, 'HorizonHours') && ...
        ismember('HorizonHours', candidateSummary.Properties.VariableNames)
    horizon = double(campaignInfo.HorizonHours(1));
    horizonValues = double(candidateSummary.HorizonHours);
    horizonMask = abs(horizonValues - horizon) < 1e-9;
    if any(horizonMask)
        mask = mask & horizonMask;
    end
end

if isfield(campaignInfo, 'StartTime') && ...
        ismember('StartTime', candidateSummary.Properties.VariableNames)
    startMask = localDatetimeMask(candidateSummary.StartTime, campaignInfo.StartTime);
    if any(startMask)
        mask = mask & startMask;
    end
end

if isfield(campaignInfo, 'FinishTime') && ...
        ismember('FinishTime', candidateSummary.Properties.VariableNames)
    finishMask = localDatetimeMask(candidateSummary.FinishTime, campaignInfo.FinishTime);
    if any(finishMask)
        mask = mask & finishMask;
    end
end

matching = candidateSummary(mask, :);
if isempty(matching) || height(matching) == 0
    return
end
if ismember('Timestamp', matching.Properties.VariableNames)
    matching = sortrows(matching, 'Timestamp');
end

startIdx = find(double(matching.Candidate) == 1, 1, 'last');
if isempty(startIdx)
    candidateCount = 5;
    if isfield(config, 'NumReleaseCandidates') && ~isempty(config.NumReleaseCandidates)
        candidateCount = max(1, double(config.NumReleaseCandidates(1)));
    end
    startIdx = max(1, height(matching) - candidateCount + 1);
end
block = matching(startIdx:end, :);

% Keep the newest row per candidate within the active batch.
candidates = unique(double(block.Candidate), 'stable');
rows = zeros(numel(candidates), 1);
for i = 1:numel(candidates)
    idx = find(double(block.Candidate) == candidates(i), 1, 'last');
    rows(i) = idx;
end
block = block(sort(rows), :);
end

function mask = localDatetimeMask(values, target)
mask = false(numel(values), 1);
try
    if isdatetime(values)
        mask = abs(days(values(:) - target)) < 1e-9;
    else
        mask = string(values(:)) == string(target);
    end
catch
end
end

function summary = localCandidateSummaryFromLog(candidateBlock, kpiAvg)
summary = table();
if isempty(candidateBlock) || height(candidateBlock) == 0
    return
end

n = height(candidateBlock);
candidate = double(candidateBlock.Candidate);
normalizedScore = localColumnNumeric(candidateBlock, 'NormalizedScore');
targetMetPct = nan(n, 1);
wipProxy = nan(n, 1);
leadHours = nan(n, 1);

for i = 1:n
    runId = "";
    if ismember('RunId', candidateBlock.Properties.VariableNames)
        runId = string(candidateBlock.RunId(i));
    end
    kpiRow = localKpiRowForRun(kpiAvg, runId);
    produced = localNumeric(kpiRow, 'TotalProduction');
    target = localNumeric(candidateBlock(i, :), 'CampaignTargetTotal');
    if isfinite(produced) && isfinite(target) && target > 0
        targetMetPct(i) = 100 * produced / target;
    end
    wipProxy(i) = localNumeric(kpiRow, 'WipProxy');
    leadHours(i) = localNumeric(kpiRow, 'MeanLeadTimeHours');
end

summary = table(candidate, normalizedScore, targetMetPct, wipProxy, leadHours, ...
    localNormalizeMetric(wipProxy), localNormalizeMetric(leadHours), ...
    'VariableNames', {'Candidate', 'NormalizedScore', 'TargetMetPct', ...
    'WipProxy', 'MeanLeadTimeHours', 'WipRel', 'LeadRel'});
end

function values = localColumnNumeric(T, name)
values = nan(height(T), 1);
name = char(name);
if ~istable(T) || ~ismember(name, T.Properties.VariableNames)
    return
end
try
    values = double(T.(name));
catch
    values = str2double(string(T.(name)));
end
end

function row = localKpiRowForRun(kpiAvg, runId)
row = table();
if strlength(runId) == 0 || isempty(kpiAvg) || height(kpiAvg) == 0 || ...
        ~ismember('RunId', kpiAvg.Properties.VariableNames)
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

function normValues = localNormalizeMetric(values)
normValues = values;
finiteValues = values(isfinite(values));
if isempty(finiteValues)
    normValues(:) = NaN;
    return
end
maxValue = max(abs(finiteValues));
if maxValue <= 0
    normValues(:) = 0;
else
    normValues = values / maxValue * 100;
end
end

function [avg, ok] = localAverageMatrix(dmResult, fieldName)
avg = [];
ok = false;
if ~isstruct(dmResult)
    return
end
names = fieldnames(dmResult);
names = names(startsWith(string(names), "run"));
if isempty(names)
    return
end
maxRows = 0;
maxCols = 0;
matrices = cell(numel(names), 1);
for i = 1:numel(names)
    current = dmResult.(names{i});
    if ~isstruct(current) || ~isfield(current, fieldName) || isempty(current.(fieldName))
        continue
    end
    M = double(current.(fieldName));
    maxRows = max(maxRows, size(M, 1));
    maxCols = max(maxCols, size(M, 2));
    matrices{i} = M;
end
if maxRows == 0 || maxCols == 0
    return
end
stack = NaN(maxRows, maxCols, numel(matrices));
for i = 1:numel(matrices)
    M = matrices{i};
    if isempty(M)
        continue
    end
    stack(1:size(M, 1), 1:size(M, 2), i) = M;
end
avg = mean(stack, 3, 'omitnan');
ok = true;
end

function M = localFiveCols(M)
M = double(M);
if isempty(M)
    M = zeros(0, 5);
    return
end
if size(M, 2) < 5
    M(:, end + 1:5) = NaN;
end
M = M(:, 1:5);
end

function values = localVector14(M)
values = double(M(:))';
if numel(values) < 14
    values(end + 1:14) = NaN;
end
values = values(1:14);
end

function value = localShiftLength(campaignInfo, config)
value = 7.5;
if isfield(campaignInfo, 'ShiftLengthHours') && ~isempty(campaignInfo.ShiftLengthHours)
    value = double(campaignInfo.ShiftLengthHours(1));
elseif isfield(config, 'ShiftLengthHours') && ~isempty(config.ShiftLengthHours)
    value = double(config.ShiftLengthHours(1));
end
end

function value = localStructValue(s, fieldName, defaultValue)
if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = s.(fieldName);
else
    value = defaultValue;
end
end
