function name = matchColumn(data, candidates)
%MATCHCOLUMN Find the first table variable matching candidate names.
%
% Matching is case-insensitive and ignores spaces, underscores, and hyphens.

name = '';
if isempty(data) || ~istable(data)
    return
end

variables = string(data.Properties.VariableNames);
normalized = cpms.normalizeNames(variables);
candidateNames = cpms.normalizeNames(string(candidates));

for i = 1:numel(candidateNames)
    idx = find(normalized == candidateNames(i), 1);
    if ~isempty(idx)
        name = char(variables(idx));
        return
    end
end

for i = 1:numel(candidateNames)
    idx = find(contains(normalized, candidateNames(i)), 1);
    if ~isempty(idx)
        name = char(variables(idx));
        return
    end
end
end
