function out = vertcatLoose(a, b)
%VERTCATLOOSE Vertically concatenate tables with different variable sets.

if isempty(a)
    out = b;
    return
end
if isempty(b)
    out = a;
    return
end

namesA = string(a.Properties.VariableNames);
namesB = string(b.Properties.VariableNames);
allNames = unique([namesA, namesB], 'stable');

for i = 1:numel(allNames)
    name = char(allNames(i));
    hasA = ismember(name, a.Properties.VariableNames);
    hasB = ismember(name, b.Properties.VariableNames);

    if ~hasA && hasB
        a.(name) = cpms.missingLike(b.(name), height(a));
    end
    if ~hasB && hasA
        b.(name) = cpms.missingLike(a.(name), height(b));
    end
end

a = a(:, cellstr(allNames));
b = b(:, cellstr(allNames));
out = [a; b];
end
