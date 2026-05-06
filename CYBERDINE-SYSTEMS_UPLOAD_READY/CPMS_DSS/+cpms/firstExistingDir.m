function folder = firstExistingDir(candidates)
%FIRSTEXISTINGDIR Return the first existing folder from CANDIDATES.

folder = '';
for i = 1:numel(candidates)
    candidate = char(candidates{i});
    if isfolder(candidate)
        folder = candidate;
        return
    end
end

folder = char(candidates{end});
end
