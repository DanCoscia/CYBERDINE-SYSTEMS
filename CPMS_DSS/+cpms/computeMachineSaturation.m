function saturation = computeMachineSaturation(logs, config)
%COMPUTEMACHINESATURATION Estimate busy-time fraction from entry/exit pairs.

data = logs.AllRows;
if isempty(data) || height(data) == 0
    byMachine = table(string(config.Machines(:)), nan(numel(config.Machines), 1), ...
        'VariableNames', {'Machine', 'Saturation'});
    saturation = struct('ByMachine', byMachine);
    return
end

id = cpms.tableStrings(data, {'PartID', 'part_id', 'partid'}, "");
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

valid = id ~= "" & machine ~= "" & ~isnat(time);
machines = string(config.Machines(:));
busyHours = zeros(numel(machines), 1);
observedStart = min(time(valid));
observedEnd = max(time(valid));
observedHours = max(hours(observedEnd - observedStart), config.ShiftLengthHours);

for m = 1:numel(machines)
    current = machines(m);
    eMask = valid & isEntry & machine == current;
    xMask = valid & isExit & machine == current;
    if ~any(eMask) || ~any(xMask)
        continue
    end

    E = table(id(eMask), time(eMask), 'VariableNames', {'PartID', 'EntryTime'});
    X = table(id(xMask), time(xMask), 'VariableNames', {'PartID', 'ExitTime'});
    J = innerjoin(E, X, 'Keys', 'PartID');
    if isempty(J)
        continue
    end
    durations = hours(J.ExitTime - J.EntryTime);
    durations = durations(isfinite(durations) & durations > 0);
    busyHours(m) = sum(durations, 'omitnan');
end

sat = min(1, busyHours ./ max(observedHours, eps));
byMachine = table(machines, sat, busyHours, repmat(observedHours, numel(machines), 1), ...
    'VariableNames', {'Machine', 'Saturation', 'BusyHours', 'ObservedHours'});

saturation = struct('ByMachine', byMachine);
end
