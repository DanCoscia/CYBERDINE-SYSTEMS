function config = resolveConfig(config)
%RESOLVECONFIG Normalize paths and choose sensible fallbacks.

config.ProjectRoot = char(config.ProjectRoot);
if ~isfield(config, 'DmDir') || isempty(config.DmDir)
    config.DmDir = config.ProjectRoot;
end
config.DmDir = char(config.DmDir);

config.RsInputDir = cpms.firstExistingDir({ ...
    config.RsInputDir, ...
    config.DmDir, ...
    fullfile(config.ProjectRoot, 'RS_Input'), ...
    fullfile(config.ProjectRoot, 'input'), ...
    fullfile(config.ProjectRoot, 'Input'), ...
    config.ProjectRoot});

config.RsOutputDir = cpms.firstExistingDir({ ...
    config.RsOutputDir, ...
    config.DmDir, ...
    fullfile(config.ProjectRoot, 'RS_Output'), ...
    fullfile(config.ProjectRoot, 'output'), ...
    fullfile(config.ProjectRoot, 'Output'), ...
    config.ProjectRoot});

config.LogDir = cpms.firstExistingDir({ ...
    config.LogDir, ...
    fullfile(config.DmDir, 'RS_FirstWeekData'), ...
    config.RsOutputDir, ...
    fullfile(config.ProjectRoot, 'Logs'), ...
    fullfile(config.ProjectRoot, 'logs'), ...
    config.ProjectRoot});

if ~isfield(config, 'DecisionOutputDir') || isempty(config.DecisionOutputDir)
    config.DecisionOutputDir = config.DmDir;
end

if isempty(config.ShiftId)
    config.ShiftId = cpms.inferShiftId(config);
end

if isempty(config.ShiftStart)
    config.ShiftStart = [];
end

if ~isfield(config, 'CourseHolidays') || isempty(config.CourseHolidays)
    config.CourseHolidays = dateshift(datetime([2025 12 8; 2025 12 25; 2025 12 26]), 'start', 'day');
else
    config.CourseHolidays = dateshift(config.CourseHolidays(:), 'start', 'day');
end

if ~isfield(config, 'ValidShiftStarts') || isempty(config.ValidShiftStarts)
    config.ValidShiftStarts = [duration(6, 30, 0), duration(14, 30, 0)];
end
if ~isfield(config, 'ValidShiftEnds') || isempty(config.ValidShiftEnds)
    config.ValidShiftEnds = [duration(14, 0, 0), duration(22, 0, 0)];
end

if ~istable(config.TargetByPart)
    error('cpms:InvalidConfig', 'TargetByPart must be a table.');
end

config.TargetByPart.PartType = string(config.TargetByPart.PartType);

mode = "weekly";
if isfield(config, 'TrainingCampaignMode') && strlength(string(config.TrainingCampaignMode)) > 0
    mode = lower(string(config.TrainingCampaignMode));
end
if mode == "final"
    mode = "full";
end
if ~isfield(config, 'TrainingStateFile') || strlength(string(config.TrainingStateFile)) == 0
    config.TrainingStateFile = fullfile(config.ProjectRoot, 'DSS_Output', ...
        "cpms_ga_training_" + mode + ".mat");
end
if ~isfield(config, 'TrainingHistoryFile') || strlength(string(config.TrainingHistoryFile)) == 0
    config.TrainingHistoryFile = fullfile(config.ProjectRoot, 'DSS_Output', ...
        "cpms_ga_history_" + mode + ".xlsx");
end
end
