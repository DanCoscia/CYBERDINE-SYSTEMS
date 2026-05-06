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
releaseTotals = localReleaseTotals(plan);
if any(isfinite(totals)) || any(releaseTotals > 0)
    bar(categorical(ptNames), [releaseTotals(:), totals(:)]);
    legend({'Released', 'Produced'}, 'Location', 'best');
    ylabel('Parts');
else
    localNoData(gca, 'No release/production data');
end
title('Release vs Produced', 'Interpreter', 'none');

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
