function releaseTable = generateReleaseTable(~, ~, kpis, config, releaseFactor)
%GENERATERELEASETABLE Create a CPMS ReleaseTable for the next shift.

if nargin < 5
    releaseFactor = 1.0;
end

targets = config.TargetByPart;
targets.PartType = string(targets.PartType);
productTypes = string(config.ProductTypes(:));

if isempty(targets) || height(targets) == 0
    targets = table(productTypes, ones(numel(productTypes), 1), ...
        'VariableNames', {'PartType', 'TargetQty'});
end

wipByPart = kpis.WIPByPart;
if isempty(wipByPart)
    wipByPart = table(targets.PartType, zeros(height(targets), 1), ...
        'VariableNames', {'PartType', 'WIP'});
end
wipByPart.PartType = string(wipByPart.PartType);

producedByPart = kpis.CumProdByPart;
if isempty(producedByPart)
    producedByPart = table(targets.PartType, zeros(height(targets), 1), ...
        'VariableNames', {'PartType', 'CumProdShift'});
end
producedByPart.PartType = string(producedByPart.PartType);

targetShift = targets.TargetQty(:) / 10;
qty = zeros(height(targets), 1);

if kpis.WIP > config.WipTarget
    wipThrottle = max(0.35, 1 - (kpis.WIP - config.WipTarget) / max(config.WipTarget, 1));
else
    wipThrottle = 1.0;
end

maxRelease = config.MaxReleasePerPart(:);
if numel(maxRelease) == 1
    maxRelease = repmat(maxRelease, height(targets), 1);
end

for i = 1:height(targets)
    partType = string(targets.PartType(i));
    currentWip = localLookup(wipByPart, 'WIP', partType, 0);
    produced = localLookup(producedByPart, 'CumProdShift', partType, 0);
    shortfall = max(0, targetShift(i) - produced);

    desired = targetShift(i) + 0.6 * shortfall;
    partWipThrottle = 1.0;
    if currentWip > 2 * targetShift(i)
        partWipThrottle = 0.55;
    elseif currentWip > targetShift(i)
        partWipThrottle = 0.75;
    end

    cap = maxRelease(min(i, numel(maxRelease)));
    qty(i) = min(cap, round(desired * releaseFactor * wipThrottle * partWipThrottle));
    if qty(i) > 0 && qty(i) < config.MinLot
        qty(i) = min(config.MinLot, cap);
    end
end

shiftStart = config.ShiftStart;
if isempty(shiftStart)
    if isfield(kpis, 'LastEventTime') && ~isnat(kpis.LastEventTime)
        shiftStart = localNextShiftStart(kpis.LastEventTime, config);
    else
        shiftStart = dateshift(datetime('now'), 'start', 'hour');
    end
end
if ~localIsProductionDay(shiftStart, config) || ~localIsValidShiftStart(shiftStart, config)
    shiftStart = localNextShiftStart(shiftStart, config);
end

releaseTime = datetime.empty(0, 1);
partTypeOut = strings(0, 1);
number = zeros(0, 1);
slot = 0;

for i = 1:height(targets)
    if qty(i) <= 0
        continue
    end
    releaseTime(end + 1, 1) = shiftStart + minutes(slot); %#ok<AGROW>
    partTypeOut(end + 1, 1) = string(targets.PartType(i)); %#ok<AGROW>
    number(end + 1, 1) = max(1, round(qty(i))); %#ok<AGROW>
    slot = slot + config.ReleaseSpacingMinutes;
end

releaseTable = table(releaseTime, partTypeOut, number, ...
    'VariableNames', {'Release Time', 'Part Type', 'Number'});
end

function value = localLookup(T, variableName, partType, defaultValue)
value = defaultValue;
if isempty(T) || ~istable(T) || ~ismember(variableName, T.Properties.VariableNames)
    return
end

idx = find(string(T.PartType) == partType, 1);
if ~isempty(idx)
    value = T.(variableName)(idx);
end
end

function nextStart = localNextShiftStart(t, config)
dayStart = dateshift(t, 'start', 'day');
morning = dayStart + hours(6) + minutes(30);
afternoon = dayStart + hours(14) + minutes(30);
nightEnd = dayStart + hours(22) + minutes(30);

if t < morning
    nextStart = morning;
elseif t < afternoon
    nextStart = afternoon;
elseif t < nightEnd
    nextStart = dayStart + days(1) + hours(6) + minutes(30);
else
    nextStart = dayStart + days(1) + hours(6) + minutes(30);
end

while ~localIsProductionDay(nextStart, config)
    nextStart = dateshift(nextStart, 'start', 'day') + days(1) + hours(6) + minutes(30);
end
end

function tf = localIsProductionDay(t, config)
d = dateshift(t, 'start', 'day');
holidays = localCourseHolidays(config);
tf = ~ismember(weekday(d), [1 7]) && ~ismember(d, holidays);
end

function holidays = localCourseHolidays(config)
if isfield(config, 'CourseHolidays') && ~isempty(config.CourseHolidays)
    holidays = dateshift(config.CourseHolidays(:), 'start', 'day');
else
    holidays = dateshift(datetime([2025 12 8; 2025 12 25; 2025 12 26]), 'start', 'day');
end
end

function tf = localIsValidShiftStart(t, config)
if isfield(config, 'ValidShiftStarts') && ~isempty(config.ValidShiftStarts)
    starts = config.ValidShiftStarts;
else
    starts = [duration(6, 30, 0), duration(14, 30, 0)];
end
tf = any(timeofday(t) == starts);
end
