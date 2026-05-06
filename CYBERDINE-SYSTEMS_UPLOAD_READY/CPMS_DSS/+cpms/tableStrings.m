function values = tableStrings(data, candidates, defaultValue)
%TABLESTRINGS Extract a string column with fallback defaults.

if nargin < 3
    defaultValue = "";
end

name = cpms.matchColumn(data, candidates);
if isempty(name)
    values = repmat(string(defaultValue), height(data), 1);
else
    values = string(data.(name));
end
end
