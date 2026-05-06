function score = extractDmScore(dmResult, config)
%EXTRACTDMSCORE Convert dm_run replications into a scalar score.
%
% Higher is better. The score rewards throughput and penalizes target
% shortfall, WIP proxy, long lead time, uneven production and saturation.

if nargin < 2
    config = struct();
end

if istable(dmResult)
    score = localScoreTable(dmResult);
    return
end

if isnumeric(dmResult) && isscalar(dmResult)
    score = dmResult;
    return
end

if ~isstruct(dmResult)
    score = -Inf;
    return
end

runs = fieldnames(dmResult);
runs = runs(startsWith(string(runs), "run"));
if isempty(runs)
    if isfield(dmResult, 'Score')
        score = dmResult.Score;
    else
        score = -Inf;
    end
    return
end

targets = zeros(1, 5);
if isfield(config, 'ScoreTargetByPart') && isnumeric(config.ScoreTargetByPart) && numel(config.ScoreTargetByPart) >= 5
    targets = double(config.ScoreTargetByPart(1:5));
elseif isfield(config, 'TargetByPart') && istable(config.TargetByPart)
    for i = 1:min(5, height(config.TargetByPart))
        targets(i) = config.TargetByPart.TargetQty(i) / 10;
    end
end
targets(~isfinite(targets) | targets < 0) = 0;

plannedRelease = nan(1, 5);
if isfield(config, 'ScorePlannedReleaseByPart') && ...
        isnumeric(config.ScorePlannedReleaseByPart) && ...
        numel(config.ScorePlannedReleaseByPart) >= 5
    plannedRelease = double(config.ScorePlannedReleaseByPart(1:5));
    plannedRelease(~isfinite(plannedRelease) | plannedRelease < 0) = 0;
end

throughput = zeros(numel(runs), 5);
wip = nan(numel(runs), 1);
lead = nan(numel(runs), 1);
sigma = nan(numel(runs), 1);
satSpread = nan(numel(runs), 1);
satMean = nan(numel(runs), 1);
satOver = nan(numel(runs), 1);
satHardOver = nan(numel(runs), 1);
satTarget = localConfigNumber(config, 'ScoreSaturationTarget', 0.85);
satHardLimit = localConfigNumber(config, 'ScoreSaturationHardLimit', 0.95);

for r = 1:numel(runs)
    current = dmResult.(runs{r});
    throughput(r, :) = localProductionTotals(current);

    if isfield(current, 'AvgBuffLevel') && ~isempty(current.AvgBuffLevel)
        wip(r) = sum(double(current.AvgBuffLevel(:)), 'omitnan');
    end
    if isfield(current, 'AvgLeadTime') && ~isempty(current.AvgLeadTime)
        lead(r) = mean(double(current.AvgLeadTime(:)), 'omitnan');
    end
    if isfield(current, 'SigmaCumProd') && ~isempty(current.SigmaCumProd)
        sigma(r) = sum(double(current.SigmaCumProd(:)), 'omitnan');
    end
    if isfield(current, 'MachSat') && ~isempty(current.MachSat)
        sat = double(current.MachSat(:));
        if localFiniteMax(sat) > 1.5
            sat = sat / 100;
        end
        satSpread(r) = std(sat, 0, 'omitnan');
        satMean(r) = localNanMean(sat);
        satOver(r) = sum(max(0, sat - satTarget), 'omitnan');
        satHardOver(r) = sum(max(0, sat - satHardLimit), 'omitnan');
    end
end

meanThroughput = mean(throughput, 1, 'omitnan');
partWeights = localPartWeights(config);
aggregateScore = localMetricScore(meanThroughput, localNanMean(wip), ...
    localNanMean(lead), localNanMean(sigma), localNanMean(satSpread), ...
    localNanMean(satMean), localNanMean(satOver), localNanMean(satHardOver), ...
    targets, partWeights, plannedRelease, config);

score = aggregateScore;
if localConfigLogical(config, 'ScoreUseRobustReplicateScore', true)
    replicateScores = nan(numel(runs), 1);
    for r = 1:numel(runs)
        replicateScores(r) = localMetricScore(throughput(r, :), wip(r), ...
            lead(r), sigma(r), satSpread(r), satMean(r), satOver(r), ...
            satHardOver(r), targets, partWeights, plannedRelease, config);
    end
    if any(isfinite(replicateScores))
        robustScore = localNanMean(replicateScores) - ...
            localConfigNumber(config, 'ScoreReplicateStdWeight', 0.50) * localNanStd(replicateScores);
        aggregateBlend = localConfigNumber(config, 'ScoreAggregateBlend', 0.25);
        aggregateBlend = max(0, min(1, aggregateBlend));
        score = aggregateBlend * aggregateScore + (1 - aggregateBlend) * robustScore;
    end
end
end

function score = localMetricScore(production, wip, lead, sigma, satSpread, ...
    satMean, satOver, satHardOver, targets, partWeights, plannedRelease, config)
production = double(production(:))';
if numel(production) < 5
    production(end + 1:5) = 0;
end
production = production(1:5);
production(~isfinite(production)) = 0;

targets = double(targets(:))';
if numel(targets) < 5
    targets(end + 1:5) = 0;
end
targets = targets(1:5);
targets(~isfinite(targets) | targets < 0) = 0;

plannedRelease = double(plannedRelease(:))';
if numel(plannedRelease) < 5
    plannedRelease(end + 1:5) = NaN;
end
plannedRelease = plannedRelease(1:5);
plannedRelease(~isfinite(plannedRelease) | plannedRelease < 0) = NaN;

shortfallByPart = max(0, targets - production);
weightedShortfall = sum(partWeights .* shortfallByPart);
priorityReward = sum((partWeights - 1) .* min(production, targets));
totalThroughput = sum(production, 'omitnan');
imbalance = std(production, 0, 'omitnan');

targetMask = targets > 0;
targetPct = zeros(1, 5);
targetPct(targetMask) = production(targetMask) ./ targets(targetMask);
totalTarget = sum(targets, 'omitnan');
if totalTarget > 0
    totalTargetPct = totalThroughput / totalTarget;
else
    totalTargetPct = 0;
end

minTotalTargetPct = localConfigNumber(config, 'ScoreMinTotalTargetPct', 0.85);
minPartTargetPct = localConfigNumber(config, 'ScoreMinPartTargetPct', 0.72);
minPT5TargetPct = localConfigNumber(config, 'ScoreMinPT5TargetPct', 0.85);
totalTargetPenalty = max(0, minTotalTargetPct - totalTargetPct);
partTargetPenalty = sum(partWeights(targetMask) .* ...
    max(0, minPartTargetPct - targetPct(targetMask)), 'omitnan');
pt5TargetPenalty = 0;
if targets(5) > 0
    pt5TargetPenalty = max(0, minPT5TargetPct - targetPct(5));
end

planEff = 0;
planEffShortfall = 0;
excessRelease = 0;
plannedMask = isfinite(plannedRelease) & plannedRelease > 0;
if any(plannedMask)
    planEffByPart = min(production(plannedMask), plannedRelease(plannedMask)) ./ ...
        plannedRelease(plannedMask);
    planEff = mean(planEffByPart, 'omitnan');
    planEffShortfall = max(0, 1 - planEff);
    excessRelease = sum(max(0, plannedRelease(plannedMask) - production(plannedMask)), 'omitnan');
end

wipOverTarget = max(0, localFiniteOrZero(wip) - ...
    localConfigNumber(config, 'WipTarget', 150));

score = ...
    12.0 * totalThroughput ...
  + 6.0  * priorityReward ...
  + localConfigNumber(config, 'ScorePlanEffWeight', 250.0) * planEff ...
  - 55.0 * weightedShortfall ...
  - 0.35 * localFiniteOrZero(wip) ...
  - localConfigNumber(config, 'ScoreWipOverTargetWeight', 2.0) * wipOverTarget ...
  - 2.0  * localFiniteOrZero(lead) ...
  - 1.5  * localFiniteOrZero(sigma) ...
  - 15.0 * imbalance ...
  - localConfigNumber(config, 'ScorePlanEffShortfallWeight', 550.0) * planEffShortfall ...
  - localConfigNumber(config, 'ScoreExcessReleaseWeight', 1.0) * excessRelease ...
  - localConfigNumber(config, 'ScoreTotalTargetShortfallWeight', 900.0) * totalTargetPenalty ...
  - localConfigNumber(config, 'ScorePartTargetShortfallWeight', 350.0) * partTargetPenalty ...
  - localConfigNumber(config, 'ScorePT5TargetShortfallWeight', 900.0) * pt5TargetPenalty ...
  - localConfigNumber(config, 'ScoreSaturationSpreadWeight', 20.0) * localFiniteOrZero(satSpread) ...
  - localConfigNumber(config, 'ScoreMeanSaturationWeight', 35.0) * localFiniteOrZero(satMean) ...
  - localConfigNumber(config, 'ScoreHighSaturationWeight', 450.0) * localFiniteOrZero(satOver) ...
  - localConfigNumber(config, 'ScoreHardSaturationWeight', 1500.0) * localFiniteOrZero(satHardOver);
end

function score = localScoreTable(T)
planEffCol = cpms.matchColumn(T, {'PlanEffShift', 'PlanEfficiency', 'Efficiency'});
wipCol = cpms.matchColumn(T, {'WIP', 'WorkInProgress'});
leadCol = cpms.matchColumn(T, {'AvLeadTime', 'LeadTime'});

score = 0;
if ~isempty(planEffCol)
    score = score + mean(cpms.tableNumbers(T, {planEffCol}, NaN), 'omitnan');
end
if ~isempty(wipCol)
    score = score - 0.01 * mean(cpms.tableNumbers(T, {wipCol}, NaN), 'omitnan');
end
if ~isempty(leadCol)
    score = score - 0.01 * mean(cpms.tableNumbers(T, {leadCol}, NaN), 'omitnan');
end
end

function totals = localProductionTotals(current)
totals = zeros(1, 5);
hasDaily = isfield(current, 'DailyCumProd') && ~isempty(current.DailyCumProd);
hasTh = isfield(current, 'ThPerShift') && ~isempty(current.ThPerShift);

dailyTotals = zeros(1, 5);
dailyTotal = 0;
if hasDaily
    cp = double(current.DailyCumProd);
    cols = min(5, size(cp, 2));
    dailyTotals(1:cols) = sum(cp(:, 1:cols), 1, 'omitnan');
    dailyTotal = sum(dailyTotals, 'omitnan');
end

thTotals = zeros(1, 5);
thTotal = 0;
nonzeroRows = 0;
if hasTh
    th = double(current.ThPerShift);
    cols = min(5, size(th, 2));
    thTotals(1:cols) = sum(th(:, 1:cols), 1, 'omitnan');
    thTotal = sum(thTotals, 'omitnan');
    nonzeroRows = sum(sum(th(:, 1:cols), 2, 'omitnan') > 0);
end

if hasDaily && (~hasTh || dailyTotal > max(1, 1.5 * thTotal) || nonzeroRows < max(3, ceil(0.25 * size(current.ThPerShift, 1))))
    totals = dailyTotals;
elseif hasTh
    totals = thTotals;
elseif hasDaily
    totals = dailyTotals;
end
end

function value = localNanMean(values)
values = values(isfinite(values));
if isempty(values)
    value = 0;
else
    value = mean(values);
end
end

function value = localNanStd(values)
values = values(isfinite(values));
if numel(values) <= 1
    value = 0;
else
    value = std(values, 0);
end
end

function value = localFiniteOrZero(value)
if isempty(value) || ~isfinite(value)
    value = 0;
else
    value = double(value(1));
end
end

function value = localFiniteMax(values)
values = values(isfinite(values));
if isempty(values)
    value = NaN;
else
    value = max(values);
end
end

function weights = localPartWeights(config)
weights = ones(1, 5);
if isfield(config, 'ScorePartWeights') && isnumeric(config.ScorePartWeights) && ...
        ~isempty(config.ScorePartWeights)
    values = double(config.ScorePartWeights(:))';
    n = min(5, numel(values));
    weights(1:n) = values(1:n);
end
weights(~isfinite(weights) | weights <= 0) = 1;
end

function value = localConfigNumber(config, fieldName, fallback)
value = fallback;
if isfield(config, fieldName) && isnumeric(config.(fieldName)) && ...
        ~isempty(config.(fieldName))
    candidate = double(config.(fieldName));
    candidate = candidate(1);
    if isfinite(candidate)
        value = candidate;
    end
end
end

function value = localConfigLogical(config, fieldName, fallback)
value = fallback;
if isfield(config, fieldName) && ~isempty(config.(fieldName))
    value = logical(config.(fieldName));
    value = value(1);
end
end
