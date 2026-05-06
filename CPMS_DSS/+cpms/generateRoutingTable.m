function routingTable = generateRoutingTable(sysState, logs, cycleTimes, config)
%GENERATEROUTINGTABLE Build the CPMS 5x14 routing percentage matrix.

if isempty(cycleTimes) || height(cycleTimes) == 0
    cycleTimes = cpms.defaultCycleTimeTable(config);
end

machines = string(config.Machines(:))';
partTypes = string(config.ProductTypes(:));
bufferLoad = localBufferLoad(sysState, config);
alarmLoad = localAlarmLoad(logs, machines);

matrix = zeros(numel(partTypes), numel(machines));
cycleMachines = string(cycleTimes.M);

for p = 1:numel(partTypes)
    pt = partTypes(p);
    for s = 1:numel(config.StageMachineGroups)
        group = config.StageMachineGroups{s};
        if s == 3 && ismember(pt, config.SkipStage3Parts)
            matrix(p, group) = 0;
            continue
        end

        scores = zeros(1, numel(group));
        for j = 1:numel(group)
            machineIdx = group(j);
            machine = machines(machineIdx);
            rowIdx = find(cycleMachines == machine, 1);
            if isempty(rowIdx) || ~ismember(char(pt), cycleTimes.Properties.VariableNames)
                baseSeconds = 1000;
            else
                baseSeconds = cycleTimes.(char(pt))(rowIdx);
                if baseSeconds <= 0 || isnan(baseSeconds)
                    baseSeconds = Inf;
                end
            end
            bufferName = "B" + extractAfter(machine, "M");
            scores(j) = baseSeconds * ...
                (1 + 0.03 * localMapValue(bufferLoad, bufferName)) * ...
                (1 + 0.08 * localMapValue(alarmLoad, machine));
        end

        matrix(p, group) = localNormalizeTo100(1 ./ scores);
    end
end

function load = localBufferLoad(sysState, config)
load = containers.Map('KeyType', 'char', 'ValueType', 'double');
try
    wip = cpms.computeWip(sysState, config);
    if isfield(wip, 'ByBuffer') && ~isempty(wip.ByBuffer)
        for i = 1:height(wip.ByBuffer)
            load(char(wip.ByBuffer.Buffer(i))) = wip.ByBuffer.WIP(i);
        end
    end
catch
end
end

function load = localAlarmLoad(logs, machines)
load = containers.Map('KeyType', 'char', 'ValueType', 'double');
for i = 1:numel(machines)
    load(char(machines(i))) = 0;
end
if ~isstruct(logs) || ~isfield(logs, 'AllRows') || isempty(logs.AllRows)
    return
end
data = logs.AllRows;
if ~ismember('LogType', data.Properties.VariableNames) || ...
        ~ismember('Machine', data.Properties.VariableNames)
    return
end
started = false(height(data), 1);
if ismember('AlarmStarted', data.Properties.VariableNames)
    started = logical(data.AlarmStarted);
end
machine = string(data.Machine);
for i = 1:numel(machines)
    load(char(machines(i))) = sum(data.LogType == "ALARM" & machine == machines(i) & started);
end
end

function value = localMapValue(map, key)
value = 0;
if isa(map, 'containers.Map') && isKey(map, char(key))
    value = map(char(key));
end
end

routingTable = array2table(matrix, 'VariableNames', cellstr(machines));
routingTable = addvars(routingTable, partTypes, 'Before', 1, 'NewVariableNames', 'PT');
end

function pct = localNormalizeTo100(weights)
weights(~isfinite(weights) | weights < 0) = 0;
if sum(weights) <= 0
    weights = ones(size(weights));
end

raw = 100 * weights ./ sum(weights);
pct = floor(raw * 1000) / 1000;
remainder = 100 - sum(pct);
[~, idx] = max(raw - pct);
pct(idx) = pct(idx) + remainder;
end
