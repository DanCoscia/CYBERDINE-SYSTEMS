function [dmResults, seeds, liveLog] = runDigitalModelLive(finishTime, config, candidateInfo)
%RUNDIGITALMODELLIVE Run the Tecnomatix DM through COM with live polling.
%
% This mirrors the visible dm_run.asv logic, but keeps the DSS in control so
% Matlab can update KPI plots while Plant Simulation is producing.

if nargin < 3 || ~isstruct(candidateInfo)
    candidateInfo = struct();
end
if ~isfield(config, 'DmReplications') || isempty(config.DmReplications)
    config.DmReplications = 8;
end
if ~isfield(config, 'LivePollSeconds') || isempty(config.LivePollSeconds)
    config.LivePollSeconds = 2;
end
if ~isfield(config, 'ProgressPrintSeconds') || isempty(config.ProgressPrintSeconds)
    config.ProgressPrintSeconds = 30;
end
if ~isfield(config, 'MaxReplicationRuntimeSeconds') || isempty(config.MaxReplicationRuntimeSeconds)
    config.MaxReplicationRuntimeSeconds = 1800;
end
if ~isfield(config, 'LivePollMetricsDuringRun') || isempty(config.LivePollMetricsDuringRun)
    config.LivePollMetricsDuringRun = false;
end
if ~isfield(config, 'ReuseLiveDashboard') || isempty(config.ReuseLiveDashboard)
    config.ReuseLiveDashboard = true;
end
if ~isfield(config, 'DashboardUpdateGranularity') || strlength(string(config.DashboardUpdateGranularity)) == 0
    config.DashboardUpdateGranularity = "campaign";
end
if ~isfield(config, 'ReloadModelEachReplication') || isempty(config.ReloadModelEachReplication)
    config.ReloadModelEachReplication = true;
end
if ~isfield(config, 'SaveDigitalModelAfterRun') || isempty(config.SaveDigitalModelAfterRun)
    config.SaveDigitalModelAfterRun = false;
end
if ~isfield(config, 'ReloadExcelInputsInLiveRunner') || isempty(config.ReloadExcelInputsInLiveRunner)
    config.ReloadExcelInputsInLiveRunner = true;
end

validateReleaseTable("ReleaseTable.xlsx");
validateRoutingTable("RoutingTable.xlsx");
validateCycleTimeTable("CycleTimeTable.xlsx");

nruns = max(1, round(double(config.DmReplications)));
runNames = arrayfun(@(k) sprintf('run%d', k), 1:nruns, 'UniformOutput', false);
innerFields = {'DailyCumProd', 'SigmaCumProd', 'MachSat', ...
    'AvgBuffLevel', 'AvgLeadTime', 'ThPerShift'};

dmResults = struct();
for i = 1:nruns
    current = struct();
    for f = 1:numel(innerFields)
        current.(innerFields{f}) = [];
    end
    dmResults.(runNames{i}) = current;
end

seeds = zeros(nruns, 1);
liveLog = table();
if ~isfield(candidateInfo, 'DashboardRunId') || strlength(string(candidateInfo.DashboardRunId)) == 0
    candidateInfo.DashboardRunId = string(datestr(now, 'yyyymmdd_HHMMSS_FFF'));
end
candidateInfo.DashboardUpdateGranularity = lower(string(config.DashboardUpdateGranularity));

try
    plantSim = actxserver('Tecnomatix.PlantSimulation.RemoteControl');
    cleanupObj = onCleanup(@() localClosePlantSim(plantSim, true));
    disp('Connected to Tecnomatix Plant Simulation via COM API.');
catch err
    error('cpms:TecnomatixConnectionFailed', ...
        'Failed to connect to Tecnomatix Plant Simulation: %s', err.message);
end

directoryPath = pwd;
files = dir(fullfile(directoryPath, '*.spp'));
if isempty(files)
    error('cpms:DigitalModelMissing', ...
        'No .spp Digital Model file found in %s.', directoryPath);
end
[~, idx] = max([files.datenum]);
modelPath = fullfile(files(idx).folder, files(idx).name);

disp('Loading Digital Model...');
plantSim.LoadModel(modelPath);
localReloadExcelInputs(plantSim, config);

dashboard = localInitDashboard(config, candidateInfo, finishTime);
pollSeconds = max(0.25, double(config.LivePollSeconds));
progressSeconds = max(pollSeconds, double(config.ProgressPrintSeconds));
maxRunSeconds = double(config.MaxReplicationRuntimeSeconds);
sampleIndex = 0;

for j = 1:nruns
    seed = localReplicationSeed(config, j);
    seeds(j) = seed;

    if j > 1 && config.ReloadModelEachReplication
        localReloadModel(plantSim, modelPath);
        localReloadExcelInputs(plantSim, config);
    end
    localResetForReplication(plantSim, finishTime, seed);
    % Tecnomatix ResetSimulation clears/rebuilds several model tables. Reload
    % the DSS workbooks after reset so each candidate actually drives the run.
    localReloadExcelInputs(plantSim, config);
    plantSim.SetValue('.Models.Model.eventController.RandomNumbersVariant', seed);

    plantSim.StartSimulation('.Models.Model');
    fprintf("Digital model run n. %d has started. \n", j);
    runTimer = tic;
    progressTimer = tic;

    while plantSim.IsSimulationRunning()
        pause(pollSeconds);
        elapsed = toc(runTimer);
        if isfinite(maxRunSeconds) && elapsed > maxRunSeconds
            localStopSimulation(plantSim);
            error('cpms:DigitalModelRunTimeout', ...
                'Digital model run %d exceeded %.0f seconds. The run was stopped.', ...
                j, maxRunSeconds);
        end
        sampleIndex = sampleIndex + 1;
        if config.LivePollMetricsDuringRun
            pollRow = localPollLiveMetrics(plantSim, candidateInfo, j, sampleIndex, finishTime);
        else
            pollRow = localProgressOnlyRow(candidateInfo, j, sampleIndex, finishTime, elapsed);
        end
        if ~isempty(pollRow)
            liveLog = cpms.vertcatLoose(liveLog, pollRow);
        end
        if config.LivePollMetricsDuringRun && localDashboardGranularity(candidateInfo) == "replication"
            localUpdateDashboard(dashboard, liveLog, dmResults, candidateInfo);
        end
        if toc(progressTimer) >= progressSeconds
            localPrintProgress(j, elapsed, pollRow);
            progressTimer = tic;
        end
    end

    runResult = localCollectRunResults(plantSim);
    runResult.Seed = seed;
    dmResults.(runNames{j}) = runResult;
    fprintf("Run n. %d results collected. \n", j);
    if localDashboardGranularity(candidateInfo) == "replication"
        localUpdateDashboard(dashboard, liveLog, dmResults, candidateInfo);
    end
end

localUpdateDashboard(dashboard, liveLog, dmResults, candidateInfo);

if config.SaveDigitalModelAfterRun
    try
        plantSim.SaveModel(modelPath);
    catch
    end
end

disp('Digital Model run complete.');
end

function dashboard = localInitDashboard(config, candidateInfo, finishTime)
dashboard = struct('Enabled', false);
if ~isfield(config, 'EnableLiveDashboard') || ~config.EnableLiveDashboard
    return
end

try
    fig = localDashboardFigure(config);
    dashboardRunId = string(localStructValue(candidateInfo, 'DashboardRunId', ""));
    priorRunId = "";
    if isappdata(fig, 'DashboardRunId')
        priorRunId = string(getappdata(fig, 'DashboardRunId'));
    end
    if strlength(dashboardRunId) > 0 && dashboardRunId ~= priorRunId
        setappdata(fig, 'DashboardHistory', table());
        setappdata(fig, 'DashboardWeeklySeries', localEmptyWeeklySeries());
        setappdata(fig, 'DashboardRunId', dashboardRunId);
    end
    candidateLabel = localCandidateLabel(candidateInfo);
    displayFinishTime = localStructValue(candidateInfo, 'DisplayFinishTime', finishTime);
    dashboard.Figure = fig;
    dashboard.AxThroughput = localDashboardAxis(fig, 'AxThroughput');
    dashboard.AxDaily = localDashboardAxis(fig, 'AxDaily');
    dashboard.AxTarget = localDashboardAxis(fig, 'AxTarget');
    dashboard.AxWip = localDashboardAxis(fig, 'AxWip');
    dashboard.AxSat = localDashboardAxis(fig, 'AxSat');
    dashboard.AxProgress = localDashboardAxis(fig, 'AxProgress');
    dashboard.Title = getappdata(fig, 'DashboardTitle');
    if ~isempty(dashboard.Title) && isvalid(dashboard.Title)
        dashboard.Title.String = sprintf('Digital Model live KPIs - %s - finish %s', ...
            candidateLabel, char(string(displayFinishTime)));
    end

    dashboard.Enabled = true;
    drawnow;
catch dashboardError
    warning('cpms:LiveDashboardInitFailed', ...
        'Live KPI dashboard could not be initialized: %s', dashboardError.message);
    dashboard = struct('Enabled', false);
end
end

function fig = localDashboardFigure(config)
needsLayout = false;
fig = [];
if isfield(config, 'ReuseLiveDashboard') && config.ReuseLiveDashboard
    fig = findobj(0, 'Type', 'figure', 'Tag', 'CPMSLiveKpiDashboard');
    if isempty(fig)
        fig = findobj(0, 'Type', 'figure', 'Name', 'CPMS Live KPI Dashboard');
        if numel(fig) > 1
            close(fig(2:end));
        end
    end
end

if isempty(fig) || ~isvalid(fig(1))
    fig = figure('Name', 'CPMS Live KPI Dashboard', ...
        'NumberTitle', 'off', 'Color', 'w', 'Tag', 'CPMSLiveKpiDashboard');
    needsLayout = true;
else
    fig = fig(1);
    set(fig, 'Tag', 'CPMSLiveKpiDashboard', 'Name', 'CPMS Live KPI Dashboard');
    needsLayout = ~isappdata(fig, 'DashboardAxes') || ~localDashboardAxesValid(fig);
    figure(fig);
end

if needsLayout
    clf(fig);
    layout = tiledlayout(fig, 2, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
    titleHandle = title(layout, 'Digital Model live KPIs', 'Interpreter', 'none');
    axesHandles = struct();

    axesHandles.AxThroughput = nexttile(layout);
    title(axesHandles.AxThroughput, 'Shift Throughput by PT');
    xlabel(axesHandles.AxThroughput, 'Shift');
    ylabel(axesHandles.AxThroughput, 'Parts');
    grid(axesHandles.AxThroughput, 'on');

    axesHandles.AxDaily = nexttile(layout);
    title(axesHandles.AxDaily, 'Daily Production by PT');
    xlabel(axesHandles.AxDaily, 'Day');
    ylabel(axesHandles.AxDaily, 'Parts');
    grid(axesHandles.AxDaily, 'on');

    axesHandles.AxTarget = nexttile(layout);
    title(axesHandles.AxTarget, 'Campaign Target Attainment');
    ylabel(axesHandles.AxTarget, 'Target met (%)');
    grid(axesHandles.AxTarget, 'on');

    axesHandles.AxWip = nexttile(layout);
    title(axesHandles.AxWip, 'WIP Proxy Progress');
    xlabel(axesHandles.AxWip, 'Completed replication');
    ylabel(axesHandles.AxWip, 'Avg buffer sum');
    grid(axesHandles.AxWip, 'on');

    axesHandles.AxSat = nexttile(layout);
    title(axesHandles.AxSat, 'Machine Saturation');
    xlabel(axesHandles.AxSat, 'Machine');
    ylabel(axesHandles.AxSat, 'Saturation');
    grid(axesHandles.AxSat, 'on');

    axesHandles.AxProgress = nexttile(layout);
    title(axesHandles.AxProgress, 'Candidate Summary');
    xlabel(axesHandles.AxProgress, 'Candidate');
    ylabel(axesHandles.AxProgress, 'Normalized metric');
    grid(axesHandles.AxProgress, 'on');

    setappdata(fig, 'DashboardAxes', axesHandles);
    setappdata(fig, 'DashboardTitle', titleHandle);
    setappdata(fig, 'DashboardHistory', table());
    setappdata(fig, 'DashboardWeeklySeries', localEmptyWeeklySeries());
end
end

function tf = localDashboardAxesValid(fig)
tf = false;
try
    axesHandles = getappdata(fig, 'DashboardAxes');
    required = {'AxThroughput', 'AxDaily', 'AxTarget', 'AxWip', 'AxSat', 'AxProgress'};
    for i = 1:numel(required)
        if ~isfield(axesHandles, required{i}) || ~isvalid(axesHandles.(required{i}))
            return
        end
    end
    tf = true;
catch
end
end

function ax = localDashboardAxis(fig, name)
axesHandles = getappdata(fig, 'DashboardAxes');
ax = axesHandles.(name);
end

function row = localPollLiveMetrics(plantSim, candidateInfo, replication, sampleIndex, finishTime)
timestamp = datetime('now');
candidate = localStructValue(candidateInfo, 'Candidate', NaN);
score = localStructValue(candidateInfo, 'Score', NaN);
normalizedScore = localStructValue(candidateInfo, 'NormalizedScore', NaN);
campaignMode = string(localStructValue(candidateInfo, 'CampaignMode', ""));
horizonHours = localStructValue(candidateInfo, 'HorizonHours', NaN);

[th, numShifts] = localReadThroughput(plantSim);
[daily, numDays] = localReadDailyProduction(plantSim);
machSat = localReadVector(plantSim, '.Models.Model.BM_stats', 1, 14);
avgBuff = localReadVector(plantSim, '.Models.Model.BM_stats', 2, 14);
avgLead = localReadVector(plantSim, '.Models.Model.PT_stats', 2, 5) ./ 3600;

ptTotals = nan(1, 5);
if ~isempty(th)
    ptTotals = sum(th(:, 1:min(5, size(th, 2))), 1, 'omitnan');
    if numel(ptTotals) < 5
        ptTotals(end + 1:5) = NaN;
    end
elseif ~isempty(daily)
    ptTotals = daily(end, 1:min(5, size(daily, 2)));
    if numel(ptTotals) < 5
        ptTotals(end + 1:5) = NaN;
    end
end

latestDailyTotal = NaN;
if ~isempty(daily)
    latestDailyTotal = sum(daily(end, 1:min(5, size(daily, 2))), 'omitnan');
end

wipProxy = sum(avgBuff, 'omitnan');
meanSat = mean(machSat, 'omitnan');
meanLead = mean(avgLead, 'omitnan');

row = table( ...
    timestamp, candidate, replication, sampleIndex, ...
    numShifts, numDays, ...
    ptTotals(1), ptTotals(2), ptTotals(3), ptTotals(4), ptTotals(5), ...
    sum(ptTotals, 'omitnan'), latestDailyTotal, wipProxy, meanSat, meanLead, ...
    score, normalizedScore, campaignMode, horizonHours, string(finishTime), ...
    'VariableNames', {'Timestamp', 'Candidate', 'Replication', 'SampleIndex', ...
    'NumShifts', 'NumDays', 'PT1', 'PT2', 'PT3', 'PT4', 'PT5', ...
    'TotalThroughput', 'LatestDailyTotal', 'WipProxy', 'MeanMachineSaturation', ...
    'MeanLeadTimeHours', 'Score', 'NormalizedScore', 'CampaignMode', ...
    'HorizonHours', 'FinishTime'});
end

function row = localProgressOnlyRow(candidateInfo, replication, sampleIndex, finishTime, elapsed)
timestamp = datetime('now');
candidate = localStructValue(candidateInfo, 'Candidate', NaN);
score = localStructValue(candidateInfo, 'Score', NaN);
normalizedScore = localStructValue(candidateInfo, 'NormalizedScore', NaN);
campaignMode = string(localStructValue(candidateInfo, 'CampaignMode', ""));
horizonHours = localStructValue(candidateInfo, 'HorizonHours', NaN);

row = table( ...
    timestamp, candidate, replication, sampleIndex, ...
    NaN, NaN, ...
    NaN, NaN, NaN, NaN, NaN, ...
    NaN, NaN, NaN, NaN, NaN, ...
    score, normalizedScore, campaignMode, horizonHours, string(finishTime), elapsed, ...
    'VariableNames', {'Timestamp', 'Candidate', 'Replication', 'SampleIndex', ...
    'NumShifts', 'NumDays', 'PT1', 'PT2', 'PT3', 'PT4', 'PT5', ...
    'TotalThroughput', 'LatestDailyTotal', 'WipProxy', 'MeanMachineSaturation', ...
    'MeanLeadTimeHours', 'Score', 'NormalizedScore', 'CampaignMode', ...
    'HorizonHours', 'FinishTime', 'ElapsedSeconds'});
end

function localUpdateDashboard(dashboard, liveLog, dmResults, candidateInfo)
if ~isstruct(dashboard) || ~isfield(dashboard, 'Enabled') || ~dashboard.Enabled
    return
end
if ~isfield(dashboard, 'Figure') || ~isvalid(dashboard.Figure)
    return
end

try
    [thAvg, hasTh] = localAverageResultMatrix(dmResults, 'ThPerShift');
    [dailyAvg, hasDaily] = localAverageResultMatrix(dmResults, 'DailyCumProd');
    [satAvg, hasSat] = localAverageResultMatrix(dmResults, 'MachSat');
    [plotThAvg, plotHasTh, plotDailyAvg, plotHasDaily, plotCandidateInfo] = ...
        localDashboardPlotView(dashboard.Figure, thAvg, hasTh, dailyAvg, hasDaily, candidateInfo);
    history = localMergeDashboardHistory(dashboard.Figure, dmResults, candidateInfo);
    recentHistory = localRecentHistory(history, 80);

    cla(dashboard.AxThroughput);
    [shiftPlot, shiftTitle, shiftXLabel] = localShiftPlotMatrix( ...
        plotThAvg, plotHasTh, plotDailyAvg, plotHasDaily, plotCandidateInfo);
    if ~isempty(shiftPlot)
        cols = min(5, size(shiftPlot, 2));
        localPlotPtMatrix(dashboard.AxThroughput, shiftPlot(:, 1:cols), shiftXLabel);
    elseif ~isempty(liveLog) && all(ismember({'PT1', 'PT2', 'PT3', 'PT4', 'PT5'}, liveLog.Properties.VariableNames))
        y = liveLog{:, {'PT1', 'PT2', 'PT3', 'PT4', 'PT5'}};
        plot(dashboard.AxThroughput, liveLog.SampleIndex, y, 'LineWidth', 1.0);
        shiftTitle = 'Live Throughput Poll by PT';
        shiftXLabel = 'Poll';
    end
    title(dashboard.AxThroughput, shiftTitle);
    xlabel(dashboard.AxThroughput, shiftXLabel);
    if contains(shiftTitle, 'TH\_SHIFT')
        ylabel(dashboard.AxThroughput, 'TH\_SHIFT rate');
    else
        ylabel(dashboard.AxThroughput, 'Parts');
    end
    grid(dashboard.AxThroughput, 'on');

    cla(dashboard.AxDaily);
    [dailyPlot, dailyTitle, dailyXLabel] = localDailyPlotMatrix( ...
        plotThAvg, plotHasTh, plotDailyAvg, plotHasDaily, plotCandidateInfo);
    if ~isempty(dailyPlot)
        localPlotPtMatrix(dashboard.AxDaily, dailyPlot, dailyXLabel);
    elseif ~isempty(liveLog) && ismember('LatestDailyTotal', liveLog.Properties.VariableNames)
        plot(dashboard.AxDaily, liveLog.SampleIndex, liveLog.LatestDailyTotal, 'LineWidth', 1.2);
        dailyTitle = 'Live Production Poll';
        dailyXLabel = 'Poll';
    end
    title(dashboard.AxDaily, dailyTitle);
    xlabel(dashboard.AxDaily, dailyXLabel);
    ylabel(dashboard.AxDaily, 'Parts');
    grid(dashboard.AxDaily, 'on');

    cla(dashboard.AxTarget);
    totals = localProductionTotals(plotDailyAvg, plotHasDaily, plotThAvg, ...
        plotHasTh, liveLog, plotCandidateInfo);
    target = localStructValue(plotCandidateInfo, 'CampaignTarget', []);
    if isempty(target)
        target = localStructValue(plotCandidateInfo, 'WeeklyTarget', []);
    end
    pct = localPercentOfTarget(totals, target);
    if any(isfinite(pct))
        bar(dashboard.AxTarget, pct);
        hold(dashboard.AxTarget, 'on');
        yline(dashboard.AxTarget, 100, 'k--', '100% target');
        hold(dashboard.AxTarget, 'off');
    else
        bar(dashboard.AxTarget, totals);
    end
    set(dashboard.AxTarget, 'XTickLabel', {'PT1', 'PT2', 'PT3', 'PT4', 'PT5'});
    title(dashboard.AxTarget, 'Campaign Target Attainment');
    ylabel(dashboard.AxTarget, 'Target met (%)');
    grid(dashboard.AxTarget, 'on');

    cla(dashboard.AxWip);
    if ~isempty(recentHistory) && ismember('WipProxy', recentHistory.Properties.VariableNames)
        y = recentHistory.WipProxy;
        plot(dashboard.AxWip, 1:numel(y), y, '-o', 'LineWidth', 1.2);
        if all(isfinite(y))
            ymin = min(y);
            ymax = max(y);
            if ymax > ymin
                ylim(dashboard.AxWip, [max(0, ymin - 0.1 * (ymax - ymin)), ymax + 0.1 * (ymax - ymin)]);
            else
                ylim(dashboard.AxWip, [max(0, ymin - 1), ymax + 1]);
            end
        end
    elseif ~isempty(liveLog) && ismember('WipProxy', liveLog.Properties.VariableNames)
        plot(dashboard.AxWip, liveLog.SampleIndex, liveLog.WipProxy, 'LineWidth', 1.2);
    end
    title(dashboard.AxWip, 'WIP Proxy Progress');
    if localDashboardGranularity(candidateInfo) == "campaign"
        if ~isempty(recentHistory) && ismember('WeekIndex', recentHistory.Properties.VariableNames) && ...
                any(isfinite(recentHistory.WeekIndex))
            xlabel(dashboard.AxWip, 'Completed weekly subcampaign');
        else
            xlabel(dashboard.AxWip, 'Completed campaign');
        end
    else
        xlabel(dashboard.AxWip, 'Completed replication');
    end
    ylabel(dashboard.AxWip, 'Avg buffer sum');
    grid(dashboard.AxWip, 'on');

    cla(dashboard.AxSat);
    if hasSat && ~isempty(satAvg)
        bar(dashboard.AxSat, satAvg(:));
        set(dashboard.AxSat, 'XTick', 1:14, 'XTickLabel', "M" + string(1:14));
    elseif ~isempty(liveLog)
        bar(dashboard.AxSat, liveLog.MeanMachineSaturation(end));
    end
    title(dashboard.AxSat, 'Machine Saturation');
    xlabel(dashboard.AxSat, 'Machine');
    ylabel(dashboard.AxSat, 'Saturation');
    grid(dashboard.AxSat, 'on');

    cla(dashboard.AxProgress);
    if ~isempty(recentHistory) && ismember('TotalProduction', recentHistory.Properties.VariableNames)
        localPlotCandidateSummary(dashboard.AxProgress, recentHistory);
    else
        repTotals = localReplicationTotals(dmResults, candidateInfo);
        if ~isempty(repTotals)
            plot(dashboard.AxProgress, 1:numel(repTotals), repTotals, '-o', 'LineWidth', 1.2);
        elseif ~isempty(liveLog) && all(ismember({'Replication', 'TotalThroughput'}, liveLog.Properties.VariableNames))
            bar(dashboard.AxProgress, liveLog.Replication(end), liveLog.TotalThroughput(end));
        end
    end
    title(dashboard.AxProgress, 'Candidate Summary');
    xlabel(dashboard.AxProgress, 'Candidate');
    ylabel(dashboard.AxProgress, 'Normalized metric');
    grid(dashboard.AxProgress, 'on');

    drawnow limitrate;
catch dashboardError
    warning('cpms:LiveDashboardUpdateFailed', ...
        'Live KPI dashboard update failed: %s', dashboardError.message);
end
end

function result = localCollectRunResults(plantSim)
result = struct();
result.DailyCumProd = localReadDailyProduction(plantSim);
result.SigmaCumProd = localReadVector(plantSim, '.Models.Model.PT_stats', 1, 5);
result.MachSat = localReadVector(plantSim, '.Models.Model.BM_stats', 1, 14);
result.AvgBuffLevel = localReadVector(plantSim, '.Models.Model.BM_stats', 2, 14);
result.AvgLeadTime = localReadVector(plantSim, '.Models.Model.PT_stats', 2, 5) ./ 3600;
result.ThPerShift = localReadThroughput(plantSim);
end

function [matrix, numShifts] = localReadThroughput(plantSim)
numShifts = localSafeGetNumber(plantSim, '.Models.Model.TH_SHIFT.yDim', 0);
matrix = zeros(numShifts, 5);
for n = 1:numShifts
    for m = 1:5
        matrix(n, m) = localSafeGetNumber(plantSim, ...
            sprintf('.Models.Model.TH_SHIFT[%d,%d]', 2 * m, n), NaN);
    end
end
end

function [matrix, numDays] = localReadDailyProduction(plantSim)
numDays = localSafeGetNumber(plantSim, '.Models.Model.CUMPROD_DAY.yDim', 0);
matrix = zeros(numDays, 5);
for n = 1:numDays
    for m = 1:5
        matrix(n, m) = localSafeGetNumber(plantSim, ...
            sprintf('.Models.Model.CUMPROD_DAY[%d,%d]', m, n), NaN);
    end
end
end

function values = localReadVector(plantSim, tablePath, rowIndex, count)
values = nan(count, 1);
for n = 1:count
    values(n, 1) = localSafeGetNumber(plantSim, ...
        sprintf('%s[%d,%d]', tablePath, rowIndex, n), NaN);
end
end

function value = localSafeGetNumber(plantSim, path, fallback)
try
    value = plantSim.GetValue(path);
    if isempty(value) || ~(isnumeric(value) || islogical(value))
        value = fallback;
    else
        value = double(value);
    end
catch
    value = fallback;
end
end

function [avg, ok] = localAverageResultMatrix(dmResults, fieldName)
ok = false;
avg = [];
if ~isstruct(dmResults)
    return
end
runs = fieldnames(dmResults);
runs = runs(startsWith(string(runs), "run"));
maxRows = 0;
maxCols = 0;
matrices = cell(numel(runs), 1);
for i = 1:numel(runs)
    current = dmResults.(runs{i});
    if ~isfield(current, fieldName) || isempty(current.(fieldName))
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
stack = NaN(maxRows, maxCols, numel(runs));
for i = 1:numel(runs)
    M = matrices{i};
    if isempty(M)
        continue
    end
    stack(1:size(M, 1), 1:size(M, 2), i) = M;
end
avg = mean(stack, 3, 'omitnan');
ok = true;
end

function [thView, hasThView, dailyView, hasDailyView, infoView] = ...
    localDashboardPlotView(fig, thAvg, hasTh, dailyAvg, hasDaily, candidateInfo)
thView = thAvg;
hasThView = hasTh;
dailyView = dailyAvg;
hasDailyView = hasDaily;
infoView = candidateInfo;

weekIndex = localStructValue(candidateInfo, 'WeekIndex', NaN);
candidate = localStructValue(candidateInfo, 'Candidate', NaN);
runId = string(localStructValue(candidateInfo, 'DashboardRunId', ""));
if ~(isnumeric(weekIndex) && isscalar(weekIndex) && isfinite(weekIndex)) || ...
        ~(isnumeric(candidate) && isscalar(candidate) && isfinite(candidate)) || ...
        strlength(runId) == 0
    return
end

series = localGetWeeklySeries(fig);
row = localWeeklySeriesRow(runId, candidate, weekIndex, thAvg, hasTh, ...
    dailyAvg, hasDaily, candidateInfo);
if isempty(series) || height(series) == 0
    series = row;
else
    emptySeries = localEmptyWeeklySeries();
    if ~all(ismember(emptySeries.Properties.VariableNames, series.Properties.VariableNames))
        series = localEmptyWeeklySeries();
    end
    series = series(string(series.RunKey) ~= string(row.RunKey), :);
    series = [series; row];
end
setappdata(fig, 'DashboardWeeklySeries', series);

same = string(series.DashboardRunId) == runId & series.Candidate == candidate;
series = series(same, :);
if isempty(series) || height(series) == 0
    return
end
[~, order] = sort(series.WeekIndex);
series = series(order, :);

[thView, hasThView, dailyView, hasDailyView, infoView] = ...
    localStitchedWeeklyView(series, candidateInfo);
end

function series = localGetWeeklySeries(fig)
if isappdata(fig, 'DashboardWeeklySeries')
    series = getappdata(fig, 'DashboardWeeklySeries');
else
    series = localEmptyWeeklySeries();
end
end

function series = localEmptyWeeklySeries()
series = table(strings(0, 1), strings(0, 1), zeros(0, 1), zeros(0, 1), ...
    cell(0, 1), cell(0, 1), cell(0, 1), cell(0, 1), ...
    'VariableNames', {'RunKey', 'DashboardRunId', 'Candidate', 'WeekIndex', ...
    'ShiftTimes', 'ThAvg', 'DailyAvg', 'CampaignTarget'});
end

function row = localWeeklySeriesRow(runId, candidate, weekIndex, thAvg, hasTh, ...
    dailyAvg, hasDaily, candidateInfo)
shiftTimes = localExpectedProductionShiftTimes(candidateInfo);
if isempty(shiftTimes)
    shiftTimes = datetime.empty(0, 1);
end
if hasTh && ~isempty(thAvg)
    th = double(thAvg);
else
    th = [];
end
if hasDaily && ~isempty(dailyAvg)
    daily = double(dailyAvg);
else
    daily = [];
end
target = localRowVector5(localStructValue(candidateInfo, 'CampaignTarget', []));
weekIndex = round(double(weekIndex));
candidate = double(candidate);
key = runId + "|" + string(candidate) + "|week" + string(weekIndex);
row = table(key, runId, candidate, weekIndex, {shiftTimes(:)}, {th}, {daily}, {target}, ...
    'VariableNames', {'RunKey', 'DashboardRunId', 'Candidate', 'WeekIndex', ...
    'ShiftTimes', 'ThAvg', 'DailyAvg', 'CampaignTarget'});
end

function [thView, hasThView, dailyView, hasDailyView, infoView] = ...
    localStitchedWeeklyView(series, candidateInfo)
thView = [];
dailyView = [];
shiftTimesView = datetime.empty(0, 1);
targetView = zeros(1, 5);
targetSeen = false;

for i = 1:height(series)
    shiftTimes = series.ShiftTimes{i};
    th = series.ThAvg{i};
    if ~isempty(th)
        if ~isempty(shiftTimes)
            n = min(size(th, 1), numel(shiftTimes));
            th = th(1:n, :);
            shiftTimesView = [shiftTimesView; shiftTimes(1:n)]; %#ok<AGROW>
        end
        thView = [thView; th]; %#ok<AGROW>
    elseif ~isempty(shiftTimes)
        shiftTimesView = [shiftTimesView; shiftTimes(:)]; %#ok<AGROW>
    end

    daily = series.DailyAvg{i};
    if ~isempty(daily)
        dailyView = [dailyView; daily]; %#ok<AGROW>
    end

    target = localRowVector5(series.CampaignTarget{i});
    finiteTarget = isfinite(target);
    if any(finiteTarget)
        targetView(finiteTarget) = targetView(finiteTarget) + target(finiteTarget);
        targetSeen = true;
    end
end

hasThView = ~isempty(thView);
hasDailyView = ~isempty(dailyView);
infoView = candidateInfo;
if ~isempty(shiftTimesView)
    infoView.ProductionShiftTimes = shiftTimesView;
    infoView.ProductionShiftCount = numel(shiftTimesView);
    infoView.ProductionDayCount = numel(unique(dateshift(shiftTimesView, 'start', 'day')));
elseif hasThView
    infoView.ProductionShiftCount = size(thView, 1);
    infoView.ProductionDayCount = max(1, ceil(size(thView, 1) / 2));
elseif hasDailyView
    infoView.ProductionDayCount = size(dailyView, 1);
end
if targetSeen
    infoView.CampaignTarget = targetView;
end
end

function out = localRowVector5(values)
out = nan(1, 5);
if isnumeric(values) && ~isempty(values)
    values = double(values(:))';
    n = min(5, numel(values));
    out(1:n) = values(1:n);
end
end

function totals = localProductionTotals(dailyAvg, hasDaily, thAvg, hasTh, liveLog, candidateInfo)
totals = zeros(1, 5);
expectedShifts = localExpectedProductionShifts(candidateInfo);
if hasTh && ~isempty(thAvg) && localThroughputLooksUsable(thAvg, expectedShifts)
    cols = min(5, size(thAvg, 2));
    totals(1:cols) = sum(thAvg(:, 1:cols), 1, 'omitnan') * localShiftLengthHours(candidateInfo);
elseif hasDaily && ~isempty(dailyAvg)
    cols = min(5, size(dailyAvg, 2));
    totals(1:cols) = sum(dailyAvg(:, 1:cols), 1, 'omitnan');
elseif ~isempty(liveLog) && all(ismember({'PT1', 'PT2', 'PT3', 'PT4', 'PT5'}, liveLog.Properties.VariableNames))
    totals = liveLog{end, {'PT1', 'PT2', 'PT3', 'PT4', 'PT5'}};
end
end

function pct = localPercentOfTarget(totals, target)
pct = nan(1, 5);
if ~isnumeric(target) || numel(target) < 5
    return
end
target = double(target(:))';
totals = double(totals(:))';
for i = 1:5
    if isfinite(target(i)) && target(i) > 0
        pct(i) = 100 * totals(i) / target(i);
    end
end
end

function localPlotCandidateSummary(ax, history)
summary = localCandidateSummaryFromHistory(history);
if isempty(summary) || height(summary) == 0
    return
end
metricMatrix = [summary.TargetMetPct, summary.WipNorm, summary.LeadNorm];
bars = bar(ax, metricMatrix, 'grouped');
set(ax, 'XTick', 1:height(summary), ...
    'XTickLabel', "C" + string(summary.Candidate));
labels = {'Target met %', 'WIP rel.', 'Lead rel.'};
n = min(numel(bars), numel(labels));
if n > 0
    legend(ax, bars(1:n), labels(1:n), 'Location', 'best');
end
end

function summary = localCandidateSummaryFromHistory(history)
summary = table();
if isempty(history) || height(history) == 0
    return
end
candidates = unique(history.Candidate, 'stable');
targetMet = nan(numel(candidates), 1);
wip = nan(numel(candidates), 1);
lead = nan(numel(candidates), 1);
prod = nan(numel(candidates), 1);
target = nan(numel(candidates), 1);
for i = 1:numel(candidates)
    rows = history(history.Candidate == candidates(i), :);
    if ismember('WeekIndex', rows.Properties.VariableNames) && any(isfinite(rows.WeekIndex))
        prod(i) = sum(rows.TotalProduction, 'omitnan');
        target(i) = sum(rows.TargetTotal, 'omitnan');
    else
        prod(i) = mean(rows.TotalProduction, 'omitnan');
        target(i) = mean(rows.TargetTotal, 'omitnan');
    end
    if isfinite(target(i)) && target(i) > 0
        targetMet(i) = 100 * prod(i) / target(i);
    end
    wip(i) = mean(rows.WipProxy, 'omitnan');
    lead(i) = mean(rows.MeanLeadTimeHours, 'omitnan');
end
wipNorm = localNormalizeMetric(wip);
leadNorm = localNormalizeMetric(lead);
summary = table(candidates(:), prod, target, targetMet, wip, lead, wipNorm, leadNorm, ...
    'VariableNames', {'Candidate', 'Production', 'Target', 'TargetMetPct', ...
    'WipProxy', 'MeanLeadTimeHours', 'WipNorm', 'LeadNorm'});
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

function localPlotPtMatrix(ax, M, xLabelText)
if isempty(M)
    return
end
cols = min(5, size(M, 2));
M = M(:, 1:cols);
if size(M, 1) == 1
    bar(ax, M(1, :));
    set(ax, 'XTick', 1:cols, 'XTickLabel', localPtLabels(cols));
else
    x = 1:size(M, 1);
    plot(ax, x, M, 'LineWidth', 1.3);
    if numel(x) <= 15
        set(ax, 'XTick', x);
    end
    xlim(ax, [max(0.5, min(x) - 0.5), max(x) + 0.5]);
    legend(ax, localPtLabels(cols), 'Location', 'best');
end
xlabel(ax, xLabelText);
end

function [M, titleText, xLabelText] = localShiftPlotMatrix(thAvg, hasTh, dailyAvg, hasDaily, ~)
M = [];
titleText = 'Shift Throughput by PT';
xLabelText = 'Shift';

if hasTh && ~isempty(thAvg)
    cols = min(5, size(thAvg, 2));
    th = thAvg(:, 1:cols);
    nonzeroRows = sum(sum(th, 2, 'omitnan') > 0);
    thTotal = sum(th(:), 'omitnan');
    dailyTotal = 0;
    if hasDaily && ~isempty(dailyAvg)
        dailyTotal = sum(dailyAvg(:, 1:min(5, size(dailyAvg, 2))), 'all', 'omitnan');
    end

    if nonzeroRows >= max(4, ceil(0.25 * size(th, 1))) || dailyTotal <= max(1, 1.5 * thTotal)
        M = th;
        titleText = 'Shift Throughput by PT (TH\_SHIFT)';
        return
    end
end

if hasDaily && ~isempty(dailyAvg)
    cols = min(5, size(dailyAvg, 2));
    M = dailyAvg(:, 1:cols);
    titleText = 'Daily Production by PT (TH\_SHIFT sparse)';
    xLabelText = 'Day';
    if isempty(M) && hasTh && ~isempty(thAvg)
        cols = min(5, size(thAvg, 2));
        M = thAvg(:, 1:cols);
        titleText = 'Shift Throughput by PT (TH\_SHIFT)';
        xLabelText = 'Shift';
    end
elseif hasTh && ~isempty(thAvg)
    cols = min(5, size(thAvg, 2));
    M = thAvg(:, 1:cols);
    titleText = 'Shift Throughput by PT (TH\_SHIFT)';
end
end

function [M, titleText, xLabelText] = localDailyPlotMatrix(thAvg, hasTh, dailyAvg, hasDaily, candidateInfo)
M = [];
titleText = 'Cumulative Daily Production by PT';
xLabelText = 'Day';

expectedDays = localExpectedProductionDays(candidateInfo);
expectedShifts = localExpectedProductionShifts(candidateInfo);
if hasTh && ~isempty(thAvg)
    cols = min(5, size(thAvg, 2));
    th = thAvg(:, 1:cols);
    if localThroughputLooksUsable(th, expectedShifts)
        daily = localAggregateShiftsToDays(th, expectedDays, candidateInfo);
        daily = daily * localShiftLengthHours(candidateInfo);
        M = cumsum(daily, 1);
        titleText = 'Cumulative Daily Production by PT (from TH\_SHIFT rate)';
        return
    end
end

if hasDaily && ~isempty(dailyAvg)
    cols = min(5, size(dailyAvg, 2));
    cumulative = cumsum(dailyAvg(:, 1:cols), 1);
    M = cumulative;
    if expectedDays > 0 && size(cumulative, 1) < max(3, expectedDays)
        titleText = sprintf('Cumulative Production by DM Period (%d rows)', size(cumulative, 1));
        xLabelText = 'DM period';
    end
end
end

function tf = localThroughputLooksUsable(th, expectedShifts)
if isempty(th)
    tf = false;
    return
end
rowTotals = sum(th, 2, 'omitnan');
nonzeroRows = sum(rowTotals > 0);
if expectedShifts <= 0 || ~isfinite(expectedShifts)
    expectedShifts = size(th, 1);
end
tf = nonzeroRows >= max(3, ceil(0.5 * min(expectedShifts, size(th, 1))));
end

function daily = localAggregateShiftsToDays(th, expectedDays, candidateInfo)
shiftTimes = localExpectedProductionShiftTimes(candidateInfo);
if ~isempty(shiftTimes)
    n = min(size(th, 1), numel(shiftTimes));
    shiftTimes = shiftTimes(1:n);
    th = th(1:n, :);
    shiftDates = dateshift(shiftTimes, 'start', 'day');
    uniqueDates = unique(shiftDates, 'stable');
    daily = zeros(numel(uniqueDates), size(th, 2));
    for d = 1:numel(uniqueDates)
        daily(d, :) = sum(th(shiftDates == uniqueDates(d), :), 1, 'omitnan');
    end
    return
end

if expectedDays <= 0 || ~isfinite(expectedDays)
    expectedDays = max(1, ceil(size(th, 1) / 2));
end
expectedDays = max(1, round(expectedDays));
daily = zeros(expectedDays, size(th, 2));
for d = 1:expectedDays
    firstRow = 2 * (d - 1) + 1;
    lastRow = min(2 * d, size(th, 1));
    if lastRow < firstRow
        continue
    end
    daily(d, :) = sum(th(firstRow:lastRow, :), 1, 'omitnan');
end
end

function n = localExpectedProductionDays(candidateInfo)
n = localStructValue(candidateInfo, 'ProductionDayCount', NaN);
if ~isfinite(n) || n <= 0
    horizonHours = localStructValue(candidateInfo, 'HorizonHours', NaN);
    if isfinite(horizonHours) && horizonHours > 0
        n = max(1, ceil(double(horizonHours) / 24));
    else
        n = NaN;
    end
end
end

function n = localExpectedProductionShifts(candidateInfo)
n = localStructValue(candidateInfo, 'ProductionShiftCount', NaN);
if ~isfinite(n) || n <= 0
    n = localStructValue(candidateInfo, 'SimulatedShifts', NaN);
end
end

function shiftTimes = localExpectedProductionShiftTimes(candidateInfo)
shiftTimes = [];
if isstruct(candidateInfo) && isfield(candidateInfo, 'ProductionShiftTimes') && ...
        ~isempty(candidateInfo.ProductionShiftTimes)
    shiftTimes = candidateInfo.ProductionShiftTimes(:);
end
end

function hoursPerShift = localShiftLengthHours(candidateInfo)
hoursPerShift = localStructValue(candidateInfo, 'ShiftLengthHours', 7.5);
if ~isfinite(hoursPerShift) || hoursPerShift <= 0
    hoursPerShift = 7.5;
end
end

function history = localMergeDashboardHistory(fig, dmResults, candidateInfo)
history = table();
if isappdata(fig, 'DashboardHistory')
    history = getappdata(fig, 'DashboardHistory');
end
newRows = localDashboardRows(dmResults, candidateInfo);
if ~isempty(newRows) && height(newRows) > 0
    history = cpms.vertcatLoose(history, newRows);
    keys = string(history.RunKey);
    [~, keepIdx] = unique(keys, 'last');
    history = history(sort(keepIdx), :);
    setappdata(fig, 'DashboardHistory', history);
end
end

function rows = localDashboardRows(dmResults, candidateInfo)
rows = table();
if ~isstruct(dmResults)
    return
end
runs = fieldnames(dmResults);
runs = runs(startsWith(string(runs), "run"));
if localDashboardGranularity(candidateInfo) == "campaign"
    rows = localDashboardCampaignRow(dmResults, runs, candidateInfo);
    return
end
runId = string(localStructValue(candidateInfo, 'DashboardRunId', ""));
candidate = localStructValue(candidateInfo, 'Candidate', NaN);
campaignMode = string(localStructValue(candidateInfo, 'CampaignMode', ""));
horizonHours = localStructValue(candidateInfo, 'HorizonHours', NaN);
weekIndex = localStructValue(candidateInfo, 'WeekIndex', NaN);
target = localStructValue(candidateInfo, 'CampaignTarget', []);
targetTotal = NaN;
if isnumeric(target)
    targetTotal = sum(target, 'omitnan');
end

for i = 1:numel(runs)
    current = dmResults.(runs{i});
    if ~localHasCompletedResult(current)
        continue
    end
    ptTotals = localRunProductionTotals(current, candidateInfo);
    totalProduction = sum(ptTotals, 'omitnan');
    wipProxy = localVectorSum(current, 'AvgBuffLevel');
    meanLead = localVectorMean(current, 'AvgLeadTime');
    meanSat = localVectorMean(current, 'MachSat');
    key = runId + "|" + string(candidate) + "|" + string(i);
    if isnumeric(weekIndex) && isfinite(weekIndex)
        key = key + "|week" + string(weekIndex);
    end
    row = table(key, runId, candidate, weekIndex, i, campaignMode, horizonHours, ...
        ptTotals(1), ptTotals(2), ptTotals(3), ptTotals(4), ptTotals(5), ...
        totalProduction, targetTotal, wipProxy, meanLead, meanSat, ...
        'VariableNames', {'RunKey', 'DashboardRunId', 'Candidate', 'WeekIndex', 'Replication', ...
        'CampaignMode', 'HorizonHours', 'PT1', 'PT2', 'PT3', 'PT4', 'PT5', ...
        'TotalProduction', 'TargetTotal', 'WipProxy', 'MeanLeadTimeHours', ...
        'MeanMachineSaturation'});
    rows = cpms.vertcatLoose(rows, row);
end
end

function row = localDashboardCampaignRow(dmResults, runs, candidateInfo)
row = table();
runId = string(localStructValue(candidateInfo, 'DashboardRunId', ""));
candidate = localStructValue(candidateInfo, 'Candidate', NaN);
campaignMode = string(localStructValue(candidateInfo, 'CampaignMode', ""));
horizonHours = localStructValue(candidateInfo, 'HorizonHours', NaN);
weekIndex = localStructValue(candidateInfo, 'WeekIndex', NaN);
target = localStructValue(candidateInfo, 'CampaignTarget', []);
targetTotal = NaN;
if isnumeric(target)
    targetTotal = sum(target, 'omitnan');
end

ptTotals = [];
wip = [];
lead = [];
sat = [];
for i = 1:numel(runs)
    current = dmResults.(runs{i});
    if ~localHasCompletedResult(current)
        continue
    end
    ptTotals(end + 1, :) = localRunProductionTotals(current, candidateInfo); %#ok<AGROW>
    wip(end + 1, 1) = localVectorSum(current, 'AvgBuffLevel'); %#ok<AGROW>
    lead(end + 1, 1) = localVectorMean(current, 'AvgLeadTime'); %#ok<AGROW>
    sat(end + 1, 1) = localVectorMean(current, 'MachSat'); %#ok<AGROW>
end
if isempty(ptTotals)
    return
end

ptMean = mean(ptTotals, 1, 'omitnan');
totalProduction = sum(ptMean, 'omitnan');
key = runId + "|" + string(candidate) + "|campaign";
if isnumeric(weekIndex) && isfinite(weekIndex)
    key = key + "|week" + string(weekIndex);
end
replication = size(ptTotals, 1);
row = table(key, runId, candidate, weekIndex, replication, campaignMode, horizonHours, ...
    ptMean(1), ptMean(2), ptMean(3), ptMean(4), ptMean(5), ...
    totalProduction, targetTotal, mean(wip, 'omitnan'), mean(lead, 'omitnan'), ...
    mean(sat, 'omitnan'), ...
    'VariableNames', {'RunKey', 'DashboardRunId', 'Candidate', 'WeekIndex', 'Replication', ...
    'CampaignMode', 'HorizonHours', 'PT1', 'PT2', 'PT3', 'PT4', 'PT5', ...
    'TotalProduction', 'TargetTotal', 'WipProxy', 'MeanLeadTimeHours', ...
    'MeanMachineSaturation'});
end

function tf = localHasCompletedResult(current)
tf = isstruct(current) && ...
    ((isfield(current, 'DailyCumProd') && ~isempty(current.DailyCumProd)) || ...
     (isfield(current, 'ThPerShift') && ~isempty(current.ThPerShift)));
end

function rows = localRecentHistory(rows, maxRows)
if isempty(rows) || height(rows) <= maxRows
    return
end
rows = rows(height(rows) - maxRows + 1:height(rows), :);
end

function totals = localRunProductionTotals(current, candidateInfo)
totals = zeros(1, 5);
if isfield(current, 'ThPerShift') && ~isempty(current.ThPerShift) && ...
        localThroughputLooksUsable(double(current.ThPerShift), ...
        localExpectedProductionShifts(candidateInfo))
    M = double(current.ThPerShift);
    cols = min(5, size(M, 2));
    totals(1:cols) = sum(M(:, 1:cols), 1, 'omitnan') * localShiftLengthHours(candidateInfo);
elseif isfield(current, 'DailyCumProd') && ~isempty(current.DailyCumProd)
    M = double(current.DailyCumProd);
    cols = min(5, size(M, 2));
    totals(1:cols) = sum(M(:, 1:cols), 1, 'omitnan');
end
end

function value = localVectorSum(s, fieldName)
if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = sum(double(s.(fieldName)(:)), 'omitnan');
else
    value = NaN;
end
end

function value = localVectorMean(s, fieldName)
if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = mean(double(s.(fieldName)(:)), 'omitnan');
else
    value = NaN;
end
end

function values = localReplicationTotals(dmResults, candidateInfo)
values = [];
if ~isstruct(dmResults)
    return
end
runs = fieldnames(dmResults);
runs = runs(startsWith(string(runs), "run"));
values = nan(numel(runs), 1);
for i = 1:numel(runs)
    current = dmResults.(runs{i});
    if localHasCompletedResult(current)
        values(i) = sum(localRunProductionTotals(current, candidateInfo), 'omitnan');
    end
end
values = values(isfinite(values));
end

function labels = localPtLabels(n)
n = min(5, n);
labels = cellstr("PT" + string(1:n));
end

function value = localStructValue(s, fieldName, fallback)
if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = s.(fieldName);
else
    value = fallback;
end
end

function granularity = localDashboardGranularity(candidateInfo)
granularity = lower(string(localStructValue(candidateInfo, 'DashboardUpdateGranularity', "campaign")));
if granularity ~= "replication"
    granularity = "campaign";
end
end

function label = localCandidateLabel(candidateInfo)
candidate = localStructValue(candidateInfo, 'Candidate', NaN);
mode = string(localStructValue(candidateInfo, 'CampaignMode', ""));
weekIndex = localStructValue(candidateInfo, 'WeekIndex', NaN);
if isfinite(candidate)
    if isfinite(weekIndex)
        label = sprintf('candidate %d %s W%d', candidate, char(mode), round(weekIndex));
    else
        label = sprintf('candidate %d %s', candidate, char(mode));
    end
else
    label = char(mode);
end
end

function localResetForReplication(plantSim, finishTime, seed)
localStopSimulation(plantSim);
plantSim.SetValue('.Models.Model.eventController.RealTime', false);
plantSim.SetValue('.Models.Model.FinishTime', finishTime);
plantSim.SetValue('.Models.Model.eventController.RandomNumbersVariant', seed);
plantSim.ResetSimulation('.Models.Model');
pause(0.1);
plantSim.SetValue('.Models.Model.eventController.RandomNumbersVariant', seed);
end

function seed = localReplicationSeed(config, replication)
useCommon = isfield(config, 'UseCommonRandomNumbers') && ...
    ~isempty(config.UseCommonRandomNumbers) && logical(config.UseCommonRandomNumbers);
seed = NaN;
if useCommon && isfield(config, 'DmSeedVector') && ~isempty(config.DmSeedVector)
    values = round(double(config.DmSeedVector(:)));
    values = values(isfinite(values) & values > 0);
    if ~isempty(values)
        seed = values(mod(replication - 1, numel(values)) + 1);
    end
end
if ~isfinite(seed)
    seed = round(0.5 + rand() * 10000);
end
seed = max(1, round(seed));
end

function localReloadModel(plantSim, modelPath)
try
    plantSim.CloseModel();
catch
end
pause(0.1);
plantSim.LoadModel(modelPath);
end

function localReloadExcelInputs(plantSim, config)
if isfield(config, 'ReloadExcelInputsInLiveRunner') && ...
        ~isempty(config.ReloadExcelInputsInLiveRunner) && ...
        ~logical(config.ReloadExcelInputsInLiveRunner(1))
    return
end

try
    plantSim.SetPathContext('.Models.Model');
catch
end

commands = { ...
    'ReleaseTable.readExcelFile("ReleaseTable.xlsx")', ...
    'RoutingTable.readExcelFile("RoutingTable.xlsx")', ...
    'SystemState.readExcelFile("SysState.xlsx")'};
absoluteCommands = { ...
    '.Models.Model.ReleaseTable.readExcelFile("ReleaseTable.xlsx")', ...
    '.Models.Model.RoutingTable.readExcelFile("RoutingTable.xlsx")', ...
    '.Models.Model.SystemState.readExcelFile("SysState.xlsx")'};
names = {'ReleaseTable.xlsx', 'RoutingTable.xlsx', 'SysState.xlsx'};

for i = 1:numel(commands)
    try
        plantSim.ExecuteSimTalk(commands{i});
    catch firstError
        try
            plantSim.ExecuteSimTalk(absoluteCommands{i});
        catch secondError
            error('cpms:DigitalModelInputReloadFailed', ...
                'Could not reload %s into the live Digital Model (%s / %s).', ...
                names{i}, firstError.message, secondError.message);
        end
    end
end
try
    plantSim.SetPathContext('.');
catch
end
end

function localPrintProgress(replication, elapsed, pollRow)
if isempty(pollRow) || height(pollRow) == 0
    fprintf('Digital model run n. %d still running after %.0f seconds.\n', ...
        replication, elapsed);
    return
end
if isfinite(pollRow.TotalThroughput(1)) || isfinite(pollRow.WipProxy(1))
    fprintf(['Digital model run n. %d still running: %.0f seconds, ', ...
        'DM shifts=%g, DM days=%g, observed throughput=%.1f, WIP proxy=%.1f.\n'], ...
        replication, elapsed, pollRow.NumShifts(1), pollRow.NumDays(1), ...
        pollRow.TotalThroughput(1), pollRow.WipProxy(1));
else
    fprintf('Digital model run n. %d still running after %.0f seconds.\n', ...
        replication, elapsed);
end
end

function localStopSimulation(plantSim)
try
    plantSim.StopSimulation('.Models.Model');
catch
    try
        plantSim.ResetSimulation('.Models.Model');
    catch
    end
end
end

function localClosePlantSim(plantSim, modelLoaded)
if isempty(plantSim)
    return
end
if modelLoaded
    try
        plantSim.CloseModel();
    catch
    end
end
try
    plantSim.Quit();
catch
end
try
    delete(plantSim);
catch
end
end
