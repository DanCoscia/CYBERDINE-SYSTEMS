function wip = computeWip(sysState, config)
%COMPUTEWIP Count WIP from the CPMS SysState buffer matrix.

parts = strings(0, 1);
buffers = strings(0, 1);
ids = strings(0, 1);

sheetNames = fieldnames(sysState.Tables);
for i = 1:numel(sheetNames)
    data = sysState.Tables.(sheetNames{i});
    if isempty(data) || height(data) == 0 || ~istable(data)
        continue
    end

    names = string(data.Properties.VariableNames);
    bufferCols = names(startsWith(names, "B", "IgnoreCase", true));
    for c = 1:numel(bufferCols)
        name = char(bufferCols(c));
        raw = string(data.(name));
        raw = raw(:);
        valid = raw ~= "" & ~ismissing(raw) & ...
            lower(raw) ~= "nan" & lower(raw) ~= "nat" & lower(raw) ~= "<missing>";
        if ~any(valid)
            continue
        end

        currentIds = raw(valid);
        currentParts = extractBefore(currentIds, "_");
        missingParts = currentParts == "" | ismissing(currentParts);
        currentParts(missingParts) = currentIds(missingParts);

        ids = [ids; currentIds]; %#ok<AGROW>
        parts = [parts; currentParts]; %#ok<AGROW>
        buffers = [buffers; repmat(string(name), numel(currentIds), 1)]; %#ok<AGROW>
    end
end

productTypes = string(config.ProductTypes(:));
if isempty(parts)
    byPart = table(productTypes, zeros(numel(productTypes), 1), ...
        'VariableNames', {'PartType', 'WIP'});
    byBuffer = table(strings(0, 1), zeros(0, 1), 'VariableNames', {'Buffer', 'WIP'});
else
    [groups, partKeys] = findgroups(parts);
    counts = splitapply(@numel, parts, groups);
    observed = table(partKeys, counts, 'VariableNames', {'PartType', 'WIP'});

    byPart = table(productTypes, zeros(numel(productTypes), 1), ...
        'VariableNames', {'PartType', 'WIP'});
    for i = 1:height(byPart)
        idx = find(observed.PartType == byPart.PartType(i), 1);
        if ~isempty(idx)
            byPart.WIP(i) = observed.WIP(idx);
        end
    end

    [bgroups, bufferKeys] = findgroups(buffers);
    bcounts = splitapply(@numel, buffers, bgroups);
    byBuffer = table(bufferKeys, bcounts, 'VariableNames', {'Buffer', 'WIP'});
end

wip = struct();
wip.Total = sum(byPart.WIP, 'omitnan');
wip.ByPart = byPart;
wip.ByBuffer = byBuffer;
wip.PartIDs = ids;
end
