function logs = readLogs(config)
%READLOGS Read CPMS CSV/XLSX logs from the configured RS output folder.

files = cpms.findFiles(config.LogDir, config.LogPatterns);
items = struct('File', {}, 'Name', {}, 'Type', {}, 'Resource', {}, ...
    'Tables', {}, 'Primary', {});

for i = 1:numel(files)
    filePath = files{i};
    [~, baseName, ext] = fileparts(filePath);
    lowerName = lower(baseName);

    if contains(lowerName, 'releasetable') || contains(lowerName, 'routingtable')
        continue
    end
    if contains(lowerName, 'sysstate')
        continue
    end

    try
        if strcmpi(ext, '.csv')
            tableData = cpms.readTableFile(filePath, config);
            tableData = localAddCanonicalColumns(tableData, filePath, baseName);
            tables = struct();
            tables.Data = tableData;
            primary = tableData;
        elseif any(strcmpi(ext, {'.xlsx', '.xls', '.xlsm'}))
            tables = cpms.readWorkbookTables(filePath, config);
            names = fieldnames(tables);
            primary = table();
            if ~isempty(names)
                primary = tables.(names{1});
            end
        else
            continue
        end
    catch readError
        warning('cpms:LogReadFailed', 'Skipping %s: %s', filePath, readError.message);
        continue
    end

    entry = struct();
    entry.File = filePath;
    entry.Name = baseName;
    entry.Type = localLogType(baseName);
    entry.Resource = localResourceFromName(baseName);
    entry.Tables = tables;
    entry.Primary = primary;
    items(end + 1) = entry; %#ok<AGROW>
end

logs = struct();
logs.Dir = config.LogDir;
logs.Items = items;
logs.AllRows = cpms.concatPrimaryTables(items);
end

function data = localAddCanonicalColumns(data, filePath, baseName)
resource = localResourceFromName(baseName);
logType = localLogType(baseName);
n = height(data);

data.SourceFile = repmat(string(filePath), n, 1);
data.SourceName = repmat(string(baseName), n, 1);
data.LogType = repmat(logType, n, 1);

resourceCol = cpms.matchColumn(data, {'resource_id', 'resource', 'machine'});
if isempty(resourceCol)
    machine = repmat(resource, n, 1);
else
    machine = string(data.(resourceCol));
    missingMachine = ismissing(machine) | machine == "" | lower(machine) == "nan";
    machine(missingMachine) = resource;
end
data.Machine = machine;

partCol = cpms.matchColumn(data, {'part_id', 'partid', 'part'});
if isempty(partCol) && ismember('Var1', data.Properties.VariableNames)
    partCol = 'Var1';
end
if isempty(partCol)
    partId = strings(n, 1);
else
    partId = string(data.(partCol));
end
data.PartID = partId;

partType = extractBefore(partId, "_");
missingType = ismissing(partType) | partType == "";
partType(missingType) = "";
data.PartType = partType;

data.EventTime = cpms.tableTimes(data, {'time', 'timestamp', 'datetime'});
if all(isnat(data.EventTime)) && ismember('Var2', data.Properties.VariableNames)
    data.EventTime = cpms.tableTimes(data, {'Var2'});
end
data.IsPartEntry = repmat(logType == "Part_ENTRY", n, 1);
data.IsPartExit = repmat(logType == "Part_EXIT", n, 1);
data.IsFinalExit = data.IsPartExit & ismember(data.Machine, "M" + string(11:14));

startedCol = cpms.matchColumn(data, {'true/false', 'truefalse', 'started', 'active'});
alarmStarted = false(n, 1);
if ~isempty(startedCol)
    raw = data.(startedCol);
    if islogical(raw)
        alarmStarted = raw;
    else
        alarmStarted = ismember(lower(string(raw)), ["true", "1", "yes"]);
    end
end
data.AlarmStarted = alarmStarted;
end

function out = localResourceFromName(baseName)
tok = regexp(baseName, '^(B\d+|M\d+)_', 'tokens', 'once');
if isempty(tok)
    out = strings(1, 1);
else
    out = string(tok{1});
end
end

function out = localLogType(baseName)
name = upper(string(baseName));
if contains(name, "PART_ENTRY")
    out = "Part_ENTRY";
elseif contains(name, "PART_EXIT")
    out = "Part_EXIT";
elseif contains(name, "ALARM")
    out = "ALARM";
elseif contains(name, "QUALITY")
    out = "QUALITY";
else
    out = "UNKNOWN";
end
end
