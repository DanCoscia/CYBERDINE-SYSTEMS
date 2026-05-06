function written = writeDecisionTables(releaseTable, routingTable, cycleTimeTable, config)
%WRITEDECISIONTABLES Write ReleaseTable, RoutingTable and CycleTimeTable.

cpms.ensureDir(config.DecisionOutputDir);
cpms.ensureDir(config.ArchiveOutputDir);

stamp = datestr(now, 'yyyymmdd_HHMMSS');
releaseName = sprintf('ReleaseTable_shift_%s.xlsx', stamp);
routingName = sprintf('RoutingTable_shift_%s.xlsx', stamp);
cycleName = sprintf('CycleTimeTable_shift_%s.xlsx', stamp);

releasePath = fullfile(config.DecisionOutputDir, 'ReleaseTable.xlsx');
routingPath = fullfile(config.DecisionOutputDir, 'RoutingTable.xlsx');
cyclePath = fullfile(config.DecisionOutputDir, 'CycleTimeTable.xlsx');
releaseArchive = fullfile(config.ArchiveOutputDir, releaseName);
routingArchive = fullfile(config.ArchiveOutputDir, routingName);
cycleArchive = fullfile(config.ArchiveOutputDir, cycleName);

if isfield(config, 'BackupExistingDecisionFiles') && config.BackupExistingDecisionFiles
    localBackupIfExists(releasePath, config.ArchiveOutputDir, 'ReleaseTable_existing', stamp);
    localBackupIfExists(routingPath, config.ArchiveOutputDir, 'RoutingTable_existing', stamp);
    localBackupIfExists(cyclePath, config.ArchiveOutputDir, 'CycleTimeTable_existing', stamp);
end
if isfield(config, 'QuarantineUnsafeInputs') && config.QuarantineUnsafeInputs
    localQuarantineUnsafeRelease(releasePath, config, stamp);
end

localDeleteIfExists(releasePath);
localDeleteIfExists(routingPath);
localDeleteIfExists(cyclePath);
writetable(releaseTable, releasePath);
writetable(routingTable, routingPath);
writetable(cycleTimeTable, cyclePath);
writetable(releaseTable, releaseArchive);
writetable(routingTable, routingArchive);
writetable(cycleTimeTable, cycleArchive);

written = struct();
written.ReleaseTable = releasePath;
written.RoutingTable = routingPath;
written.CycleTimeTable = cyclePath;
written.ReleaseArchive = releaseArchive;
written.RoutingArchive = routingArchive;
written.CycleTimeArchive = cycleArchive;
end

function localDeleteIfExists(path)
if ~isfile(path)
    return
end
try
    delete(path);
catch deleteError
    error('cpms:DecisionWorkbookLocked', ...
        'Could not replace %s. Close Excel/Tecnomatix and retry. Details: %s', ...
        path, deleteError.message);
end
end

function localBackupIfExists(path, archiveDir, prefix, stamp)
if ~isfile(path)
    return
end
[~, ~, ext] = fileparts(path);
copyfile(path, fullfile(archiveDir, sprintf('%s_%s%s', prefix, stamp, ext)));
end

function localQuarantineUnsafeRelease(path, config, stamp)
if ~isfile(path)
    return
end

[isUnsafe, reason] = localUnsafeReleaseReason(path, config);
if ~isUnsafe
    return
end

quarantineDir = fullfile(config.ArchiveOutputDir, 'quarantine');
if isfield(config, 'QuarantineDir') && strlength(string(config.QuarantineDir)) > 0
    quarantineDir = config.QuarantineDir;
end
cpms.ensureDir(quarantineDir);

[~, name, ext] = fileparts(path);
dst = fullfile(quarantineDir, sprintf('%s_quarantined_%s%s', name, stamp, ext));
try
    movefile(path, dst);
    localAppendQuarantineManifest(quarantineDir, path, dst, reason);
catch
    try
        copyfile(path, dst);
        localAppendQuarantineManifest(quarantineDir, path, dst, ...
            "copy only, move failed: " + reason);
    catch
        warning('cpms:QuarantineFailed', ...
            'Unsafe ReleaseTable was detected but could not be quarantined: %s', path);
    end
end
end

function [isUnsafe, reason] = localUnsafeReleaseReason(path, config)
isUnsafe = false;
reason = "";
try
    T = readtable(path, 'VariableNamingRule', 'preserve');
catch err
    isUnsafe = true;
    reason = "could not read existing release table: " + string(err.message);
    return
end

required = ["Release Time", "Part Type", "Number"];
if ~all(ismember(required, string(T.Properties.VariableNames)))
    isUnsafe = true;
    reason = "missing required release columns";
    return
end

qty = double(T.Number);
totalQty = sum(qty, 'omitnan');
maxRows = 100;
maxTotal = 5000;
if isfield(config, 'TargetByPart') && istable(config.TargetByPart)
    maxTotal = max(maxTotal, 3 * sum(double(config.TargetByPart.TargetQty), 'omitnan'));
end
mode = "";
if isfield(config, 'TrainingCampaignMode')
    mode = lower(string(config.TrainingCampaignMode));
end
if mode == "full" || mode == "final" || (isfield(config, 'DmHorizonHours') && double(config.DmHorizonHours) > 7 * 24)
    maxRows = 500;
    if isfield(config, 'TargetByPart') && istable(config.TargetByPart)
        maxTotal = max(maxTotal, 10 * sum(double(config.TargetByPart.TargetQty), 'omitnan'));
    end
elseif mode == "weekly"
    maxRows = 100;
end
if height(T) > maxRows
    isUnsafe = true;
    reason = sprintf('row count %d exceeds current-shift safety cap %d', height(T), maxRows);
elseif totalQty > maxTotal
    isUnsafe = true;
    reason = sprintf('total release %.0f exceeds safety cap %.0f', totalQty, maxTotal);
elseif any(qty < 0 | ~isfinite(qty))
    isUnsafe = true;
    reason = "release quantities contain negative or nonfinite values";
    return
end

releaseTimes = T.("Release Time");
if ~isdatetime(releaseTimes)
    try
        releaseTimes = datetime(releaseTimes);
    catch
        isUnsafe = true;
        reason = "release times are not valid datetimes";
        return
    end
end

releaseDates = dateshift(releaseTimes, 'start', 'day');
holidays = dateshift(datetime([2025 12 8; 2025 12 25; 2025 12 26]), 'start', 'day');
if isfield(config, 'CourseHolidays') && ~isempty(config.CourseHolidays)
    holidays = dateshift(config.CourseHolidays(:), 'start', 'day');
end
badDay = ismember(weekday(releaseDates), [1 7]) | ismember(releaseDates, holidays);
if any(badDay)
    isUnsafe = true;
    reason = sprintf('contains %d releases on weekends or course holidays', nnz(badDay));
    return
end

timeOfDay = timeofday(releaseTimes);
inMorning = timeOfDay >= duration(6,30,0) & timeOfDay < duration(14,0,0);
inAfternoon = timeOfDay >= duration(14,30,0) & timeOfDay < duration(22,0,0);
if any(~(inMorning | inAfternoon))
    isUnsafe = true;
    reason = sprintf('contains %d releases outside valid shift windows', nnz(~(inMorning | inAfternoon)));
end
end

function localAppendQuarantineManifest(quarantineDir, src, dst, reason)
manifestPath = fullfile(quarantineDir, 'quarantine_manifest.xlsx');
row = table(datetime('now'), string(src), string(dst), string(reason), ...
    'VariableNames', {'Timestamp', 'SourcePath', 'QuarantinePath', 'Reason'});
if isfile(manifestPath)
    try
        old = readtable(manifestPath, 'VariableNamingRule', 'preserve', 'TextType', 'string');
        row = cpms.vertcatLoose(old, row);
    catch
    end
end
writetable(row, manifestPath);
end
