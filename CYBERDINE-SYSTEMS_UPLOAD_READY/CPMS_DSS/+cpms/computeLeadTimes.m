function leadTime = computeLeadTimes(logs)
%COMPUTELEADTIMES Estimate lead time from first entry to final exit.

data = logs.AllRows;
if isempty(data) || height(data) == 0
    leadTime = struct('AvLeadTime', NaN, 'ByPart', table());
    return
end

id = cpms.tableStrings(data, {'PartID', 'part_id', 'partid'}, "");
part = cpms.tableStrings(data, {'PartType', 'part_id', 'partid'}, "");
needsExtract = contains(part, "_");
part(needsExtract) = extractBefore(part(needsExtract), "_");
time = data.EventTime;
if ~isdatetime(time)
    time = cpms.tableTimes(data, {'EventTime', 'time', 'timestamp'});
end

valid = id ~= "" & ~isnat(time) & part ~= "";
if ~any(valid)
    leadTime = struct('AvLeadTime', NaN, 'ByPart', table());
    return
end

id = id(valid);
part = part(valid);
time = time(valid);

if ismember('IsPartEntry', data.Properties.VariableNames)
    isRelease = logical(data.IsPartEntry(valid));
else
    isRelease = contains(upper(string(data.SourceName(valid))), "PART_ENTRY");
end
if ismember('IsFinalExit', data.Properties.VariableNames)
    isFinish = logical(data.IsFinalExit(valid));
else
    machine = cpms.tableStrings(data(valid, :), {'Machine', 'resource_id'}, "");
    isFinish = contains(upper(string(data.SourceName(valid))), "PART_EXIT") & ...
        ismember(machine, "M" + string(11:14));
end

ids = unique(id);
rows = table();
for i = 1:numel(ids)
    idx = id == ids(i);
    startTimes = time(idx & isRelease);
    endTimes = time(idx & isFinish);
    if isempty(startTimes) || isempty(endTimes)
        continue
    end

    partValue = part(find(idx, 1));
    ltHours = hours(max(endTimes) - min(startTimes));
    if ltHours >= 0
        rows = [rows; table(partValue, ltHours, 'VariableNames', {'PartType', 'LeadTimeHours'})]; %#ok<AGROW>
    end
end

if isempty(rows)
    leadTime = struct('AvLeadTime', NaN, 'ByPart', table());
    return
end

groups = findgroups(rows.PartType);
partKeys = splitapply(@(x) x(1), rows.PartType, groups);
avg = splitapply(@(x) median(x, 'omitnan'), rows.LeadTimeHours, groups);
byPart = table(partKeys, avg, 'VariableNames', {'PartType', 'AvLeadTime'});

leadTime = struct();
leadTime.AvLeadTime = median(rows.LeadTimeHours, 'omitnan');
leadTime.ByPart = byPart;
end
