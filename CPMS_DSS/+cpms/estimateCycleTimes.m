function cycleTimes = estimateCycleTimes(logs, config)
%ESTIMATECYCLETIMES Estimate CycleTimeTable.xlsx from first-week logs.

data = logs.AllRows;
if isempty(data) || height(data) == 0
    cycleTimes = cpms.defaultCycleTimeTable(config);
    return
end

id = cpms.tableStrings(data, {'PartID', 'part_id', 'partid'}, "");
part = cpms.tableStrings(data, {'PartType', 'part_id', 'partid'}, "");
needsExtract = contains(part, "_");
part(needsExtract) = extractBefore(part(needsExtract), "_");
machine = cpms.tableStrings(data, {'Machine', 'resource_id', 'resource'}, "");
time = data.EventTime;
if ~isdatetime(time)
    time = cpms.tableTimes(data, {'EventTime', 'time', 'timestamp'});
end

if ismember('IsPartEntry', data.Properties.VariableNames)
    isEntry = logical(data.IsPartEntry);
else
    isEntry = contains(upper(string(data.SourceName)), "PART_ENTRY");
end
if ismember('IsPartExit', data.Properties.VariableNames)
    isExit = logical(data.IsPartExit);
else
    isExit = contains(upper(string(data.SourceName)), "PART_EXIT");
end

valid = id ~= "" & part ~= "" & machine ~= "" & ~isnat(time);
if ~any(valid)
    cycleTimes = cpms.defaultCycleTimeTable(config);
    return
end

base = cpms.defaultCycleTimeTable(config);
machines = string(base.M);
parts = string(config.ProductTypes(:))';
matrix = table2array(base(:, cellstr(parts)));
observations = zeros(size(matrix));

for m = 1:numel(machines)
    currentMachine = machines(m);
    eMask = valid & isEntry & machine == currentMachine;
    xMask = valid & isExit & machine == currentMachine;
    if ~any(eMask) || ~any(xMask)
        continue
    end

    E = table(id(eMask), part(eMask), time(eMask), ...
        'VariableNames', {'PartID', 'PartType', 'EntryTime'});
    X = table(id(xMask), time(xMask), ...
        'VariableNames', {'PartID', 'ExitTime'});
    J = innerjoin(E, X, 'Keys', 'PartID');
    if isempty(J)
        continue
    end

    secondsValue = seconds(J.ExitTime - J.EntryTime);
    validDuration = isfinite(secondsValue) & secondsValue > 0;
    J = J(validDuration, :);
    secondsValue = secondsValue(validDuration);

    for p = 1:numel(parts)
        if matrix(m, p) == 0
            continue
        end
        values = secondsValue(J.PartType == parts(p));
        if isempty(values)
            continue
        end
        matrix(m, p) = max(1, round(localRobustSeconds(values)));
        observations(m, p) = numel(values);
    end
end

cycleTimes = array2table(matrix, 'VariableNames', cellstr(parts));
cycleTimes = addvars(cycleTimes, machines(:), 'Before', 1, 'NewVariableNames', 'M');
cycleTimes.Properties.UserData.Observations = observations;
end

function value = localRobustSeconds(values)
values = sort(values(:));
values = values(isfinite(values) & values > 0);
if isempty(values)
    value = NaN;
    return
end

n = numel(values);
if n >= 8
    trim = max(1, floor(0.1 * n));
    trimmed = values((trim + 1):(n - trim));
    value = 0.5 * median(values, 'omitnan') + 0.5 * mean(trimmed, 'omitnan');
else
    value = median(values, 'omitnan');
end
end
