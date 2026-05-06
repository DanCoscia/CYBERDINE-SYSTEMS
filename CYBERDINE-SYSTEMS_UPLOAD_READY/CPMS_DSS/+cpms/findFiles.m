function files = findFiles(rootDir, patterns)
%FINDFILES Return files matching any PATTERNS recursively under ROOTDIR.

if ischar(patterns) || isstring(patterns)
    patterns = cellstr(patterns);
end

if ~isfolder(rootDir)
    files = {};
    return
end

files = {};
for i = 1:numel(patterns)
    pattern = patterns{i};
    direct = dir(fullfile(rootDir, pattern));
    nested = dir(fullfile(rootDir, '**', pattern));
    matches = [direct(:); nested(:)];
    for j = 1:numel(matches)
        if matches(j).isdir
            continue
        end
        files{end + 1, 1} = fullfile(matches(j).folder, matches(j).name); %#ok<AGROW>
    end
end

files = unique(files, 'stable');
end
