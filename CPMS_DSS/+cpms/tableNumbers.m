function values = tableNumbers(data, candidates, defaultValue)
%TABLENUMBERS Extract a numeric column with fallback defaults.

if nargin < 3
    defaultValue = NaN;
end

name = cpms.matchColumn(data, candidates);
if isempty(name)
    values = repmat(defaultValue, height(data), 1);
    return
end

raw = data.(name);
if isnumeric(raw) || islogical(raw)
    values = double(raw);
elseif isduration(raw)
    values = hours(raw);
elseif isdatetime(raw)
    values = datenum(raw);
else
    values = str2double(string(raw));
end
end
