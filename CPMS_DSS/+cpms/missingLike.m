function values = missingLike(template, n)
%MISSINGLIKE Create an n-row missing column with TEMPLATE's type.

if isdatetime(template)
    values = NaT(n, size(template, 2));
elseif isduration(template)
    values = seconds(NaN(n, size(template, 2)));
elseif isstring(template)
    values = strings(n, size(template, 2));
elseif isnumeric(template)
    values = NaN(n, size(template, 2));
elseif islogical(template)
    values = false(n, size(template, 2));
elseif iscategorical(template)
    values = categorical(repmat(missing, n, size(template, 2)), categories(template));
elseif iscell(template)
    values = cell(n, size(template, 2));
else
    values = strings(n, 1);
end
end
