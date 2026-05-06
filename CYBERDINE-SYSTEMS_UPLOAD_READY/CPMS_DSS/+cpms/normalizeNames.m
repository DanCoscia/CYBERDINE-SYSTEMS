function names = normalizeNames(names)
%NORMALIZENAMES Normalize names for schema matching.

names = lower(string(names));
names = regexprep(names, '[\s_\-()./\\]+', '');
end
