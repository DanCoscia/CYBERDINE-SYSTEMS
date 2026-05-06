function ensureDir(folder)
%ENSUREDIR Create FOLDER when it does not exist.

if ~isfolder(folder)
    mkdir(folder);
end
end
