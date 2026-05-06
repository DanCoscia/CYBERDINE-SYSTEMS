function sysState = readLatestSysState(config)
%READLATESTSYSSTATE Read the newest SysState workbook from RS outputs.

filePath = cpms.findLatestFile(config.RsOutputDir, config.SysStatePattern);
if isempty(filePath)
    sysState = struct();
    sysState.File = '';
    sysState.Tables = struct();
    sysState.Primary = table();
    warning('cpms:SysStateMissing', ...
        'No SysState file matching "%s" found under %s.', ...
        config.SysStatePattern, config.RsOutputDir);
    return
end

tables = cpms.readWorkbookTables(filePath, config);
sheetNames = fieldnames(tables);
primary = table();
if ~isempty(sheetNames)
    primary = tables.(sheetNames{1});
end

sysState = struct();
sysState.File = filePath;
sysState.Tables = tables;
sysState.Primary = primary;
end
