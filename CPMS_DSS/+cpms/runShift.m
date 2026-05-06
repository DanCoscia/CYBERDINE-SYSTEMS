function result = runShift(config)
%RUNSHIFT Orchestrate one RS-observe, DSS-decide, RS-input-write cycle.

config = cpms.resolveConfig(config);
if config.Verbose
    fprintf('CPMS DSS root: %s\n', config.ProjectRoot);
end

sysState = cpms.readLatestSysState(config);
logs = cpms.readLogs(config);
cycleTimes = cpms.estimateCycleTimes(logs, config);
kpis = cpms.computeKpis(sysState, logs, config);

releaseCandidates = cpms.generateReleaseCandidates(sysState, logs, kpis, config);
routingTable = cpms.generateRoutingTable(sysState, logs, cycleTimes, config);

[releaseTable, routingTable, dmScores, trainingState] = cpms.selectReleaseWithDigitalModel( ...
    releaseCandidates, routingTable, cycleTimes, sysState, config);

writtenFiles = cpms.writeDecisionTables(releaseTable, routingTable, cycleTimes, config);
writtenFiles = localSyncDmWorkTables(writtenFiles, releaseTable, routingTable, cycleTimes, config);

result = struct();
result.Config = config;
result.SysState = sysState;
result.Logs = logs;
result.Kpis = kpis;
result.CycleTimeTable = cycleTimes;
result.ReleaseTable = releaseTable;
result.RoutingTable = routingTable;
result.DigitalModelScores = dmScores;
result.TrainingState = trainingState;
result.WrittenFiles = writtenFiles;

if config.Verbose
    fprintf('Wrote %s\n', writtenFiles.ReleaseTable);
    fprintf('Wrote %s\n', writtenFiles.RoutingTable);
    fprintf('Wrote %s\n', writtenFiles.CycleTimeTable);
end

function writtenFiles = localSyncDmWorkTables(writtenFiles, releaseTable, routingTable, cycleTimes, config)
if ~isfield(config, 'UseDmWorkingCopy') || ~config.UseDmWorkingCopy || ...
        ~isfield(config, 'DmWorkDir') || ~isfolder(config.DmWorkDir)
    return
end

try
    releasePath = fullfile(config.DmWorkDir, 'ReleaseTable.xlsx');
    routingPath = fullfile(config.DmWorkDir, 'RoutingTable.xlsx');
    cyclePath = fullfile(config.DmWorkDir, 'CycleTimeTable.xlsx');
    localDeleteIfExists(releasePath);
    localDeleteIfExists(routingPath);
    localDeleteIfExists(cyclePath);
    writetable(releaseTable, releasePath);
    writetable(routingTable, routingPath);
    writetable(cycleTimes, cyclePath);
    writtenFiles.DmWorkReleaseTable = releasePath;
    writtenFiles.DmWorkRoutingTable = routingPath;
    writtenFiles.DmWorkCycleTimeTable = cyclePath;
catch syncError
    warning('cpms:DmWorkSyncFailed', ...
        'Could not synchronize final decision tables to DM_Work: %s', syncError.message);
end
end

function localDeleteIfExists(path)
if ~isfile(path)
    return
end
try
    delete(path);
catch deleteError
    error('cpms:DmWorkWorkbookLocked', ...
        'Could not replace %s. Close Excel/Tecnomatix and retry. Details: %s', ...
        path, deleteError.message);
end
end
end
