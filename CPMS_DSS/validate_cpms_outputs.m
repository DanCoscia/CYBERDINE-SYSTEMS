function result = validate_cpms_outputs(varargin)
%VALIDATE_CPMS_OUTPUTS Generate and validate DSS tables without running DM/RS.
%
%   RESULT = VALIDATE_CPMS_OUTPUTS() writes temporary ReleaseTable,
%   RoutingTable, and CycleTimeTable files, validates them with the course
%   validators, then removes the temporary files.
%
%   RESULT = VALIDATE_CPMS_OUTPUTS('KeepFiles', true) keeps the generated
%   files under DSS_Output/validation_latest for inspection.

projectRoot = fileparts(mfilename('fullpath'));
addpath(projectRoot);

p = inputParser;
addParameter(p, 'KeepFiles', false, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'OutputDir', '', @(x) ischar(x) || isstring(x));
parse(p, varargin{:});
opt = p.Results;

if strlength(string(opt.OutputDir)) > 0
    outputDir = char(opt.OutputDir);
    keepFiles = true;
elseif opt.KeepFiles
    outputDir = fullfile(projectRoot, 'DSS_Output', 'validation_latest');
    keepFiles = true;
else
    outputDir = fullfile(tempdir, ['cpms_validation_' char(java.util.UUID.randomUUID)]);
    keepFiles = false;
end

archiveDir = fullfile(outputDir, 'archive');
cleanupObj = [];
if ~keepFiles
    cleanupObj = onCleanup(@() localRemoveDir(outputDir)); %#ok<NASGU>
end

config = cpms.defaultConfig();
config.ProjectRoot = projectRoot;
config.DecisionOutputDir = outputDir;
config.ArchiveOutputDir = archiveDir;
config.UseDigitalModelScoring = false;
config.UseDmWorkingCopy = false;
config.Verbose = false;

result = cpms.runShift(config);

addpath(config.DmDir);
validateReleaseTable(result.WrittenFiles.ReleaseTable);
validateRoutingTable(result.WrittenFiles.RoutingTable);
validateCycleTimeTable(result.WrittenFiles.CycleTimeTable);

fprintf('CPMS output validation complete.\n');
if keepFiles
    fprintf('Validated files kept at: %s\n', outputDir);
else
    fprintf('Temporary validation files removed.\n');
end
end

function localRemoveDir(path)
if isfolder(path)
    try
        rmdir(path, 's');
    catch
    end
end
end
