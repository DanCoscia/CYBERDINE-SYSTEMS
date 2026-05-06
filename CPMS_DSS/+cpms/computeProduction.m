function production = computeProduction(logs, config)
%COMPUTEPRODUCTION Compute CPMS finished output from M11-M14 exit logs.

data = logs.AllRows;
if isempty(data) || height(data) == 0
    production = localEmptyProduction(config);
    return
end

part = cpms.tableStrings(data, {'PartType', 'part_id', 'partid'}, "");
needsExtract = contains(part, "_");
part(needsExtract) = extractBefore(part(needsExtract), "_");
time = data.EventTime;
if ~isdatetime(time)
    time = cpms.tableTimes(data, {'EventTime', 'time', 'timestamp'});
end

if ismember('IsFinalExit', data.Properties.VariableNames)
    isProduced = logical(data.IsFinalExit);
else
    machine = cpms.tableStrings(data, {'Machine', 'resource_id', 'resource'}, "");
    isExit = contains(upper(string(data.SourceName)), "PART_EXIT");
    isProduced = isExit & ismember(machine, "M" + string(11:14));
end

valid = isProduced & ~isnat(time) & part ~= "";
if ~any(valid)
    production = localEmptyProduction(config);
    return
end

part = part(valid);
time = time(valid);
lastEvent = max(time);

shiftStart = config.ShiftStart;
if isempty(shiftStart)
    shiftStart = localShiftStartForTime(lastEvent);
end
shiftEnd = shiftStart + hours(config.ShiftLengthHours);
inShift = time >= shiftStart & time < shiftEnd;

byPart = localCountByPart(part(inShift), config, 'CumProdShift');
throughput = table(byPart.PartType, byPart.CumProdShift ./ config.ShiftLengthHours, ...
    'VariableNames', {'PartType', 'Throughput'});

shiftBucket = arrayfun(@localShiftStartForTime, time);
[g, bucketKeys, partKeys] = findgroups(shiftBucket, part);
counts = splitapply(@numel, part, g);
shiftCounts = table(bucketKeys, partKeys, counts, ...
    'VariableNames', {'ShiftStart', 'PartType', 'Produced'});

sigmaRows = table(string(config.ProductTypes(:)), zeros(numel(config.ProductTypes), 1), ...
    'VariableNames', {'PartType', 'SigmaCumProd'});
for i = 1:height(sigmaRows)
    vals = shiftCounts.Produced(shiftCounts.PartType == sigmaRows.PartType(i));
    if numel(vals) > 1
        sigmaRows.SigmaCumProd(i) = std(vals, 0, 'omitnan');
    else
        sigmaRows.SigmaCumProd(i) = 0;
    end
end

totalByPart = localCountByPart(part, config, 'CumProdTotal');

production = struct();
production.CumProdShift = sum(byPart.CumProdShift, 'omitnan');
production.ByPart = byPart;
production.CumProdTotal = sum(totalByPart.CumProdTotal, 'omitnan');
production.TotalByPart = totalByPart;
production.SigmaCumProd = sigmaRows;
production.ThroughputByPart = throughput;
production.LastEventTime = lastEvent;
production.ShiftStart = shiftStart;
production.ShiftEnd = shiftEnd;
production.ShiftCounts = shiftCounts;
end

function production = localEmptyProduction(config)
byPart = table(string(config.ProductTypes(:)), zeros(numel(config.ProductTypes), 1), ...
    'VariableNames', {'PartType', 'CumProdShift'});
totalByPart = table(byPart.PartType, zeros(height(byPart), 1), ...
    'VariableNames', {'PartType', 'CumProdTotal'});
throughput = table(byPart.PartType, zeros(height(byPart), 1), ...
    'VariableNames', {'PartType', 'Throughput'});
sigmaRows = table(byPart.PartType, zeros(height(byPart), 1), ...
    'VariableNames', {'PartType', 'SigmaCumProd'});
production = struct('CumProdShift', 0, 'ByPart', byPart, ...
    'CumProdTotal', 0, 'TotalByPart', totalByPart, 'SigmaCumProd', sigmaRows, ...
    'ThroughputByPart', throughput, 'LastEventTime', NaT, ...
    'ShiftStart', NaT, 'ShiftEnd', NaT, 'ShiftCounts', table());
end

function byPart = localCountByPart(part, config, variableName)
productTypes = string(config.ProductTypes(:));
byPart = table(productTypes, zeros(numel(productTypes), 1), ...
    'VariableNames', {'PartType', variableName});
if isempty(part)
    return
end

[g, keys] = findgroups(part);
counts = splitapply(@numel, part, g);
for i = 1:height(byPart)
    idx = find(keys == byPart.PartType(i), 1);
    if ~isempty(idx)
        byPart.(variableName)(i) = counts(idx);
    end
end
end

function shiftStart = localShiftStartForTime(t)
dayStart = dateshift(t, 'start', 'day');
morning = dayStart + hours(6) + minutes(30);
afternoon = dayStart + hours(14) + minutes(30);
nightEnd = dayStart + hours(22) + minutes(30);

if t >= afternoon && t < nightEnd
    shiftStart = afternoon;
elseif t >= morning
    shiftStart = morning;
else
    previous = dayStart - days(1);
    shiftStart = previous + hours(14) + minutes(30);
end
end
