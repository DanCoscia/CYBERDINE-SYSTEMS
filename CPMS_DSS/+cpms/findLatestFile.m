function filePath = findLatestFile(rootDir, pattern)
%FINDLATESTFILE Return the newest file matching PATTERN under ROOTDIR.

files = cpms.findFiles(rootDir, {pattern});
if isempty(files)
    filePath = '';
    return
end

timestamps = NaT(numel(files), 1);
for i = 1:numel(files)
    info = dir(files{i});
    timestamps(i) = datetime(info.datenum, 'ConvertFrom', 'datenum');
end

[~, idx] = max(timestamps);
filePath = files{idx};
end
