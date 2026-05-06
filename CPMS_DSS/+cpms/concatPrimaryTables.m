function out = concatPrimaryTables(items)
%CONCATPRIMARYTABLES Stack log primary tables with a SourceFile column.

out = table();
for i = 1:numel(items)
    data = items(i).Primary;
    if isempty(data) || height(data) == 0
        continue
    end

    data.SourceFile = repmat(string(items(i).File), height(data), 1);
    if isempty(out)
        out = data;
        continue
    end

    out = cpms.vertcatLoose(out, data);
end
end
