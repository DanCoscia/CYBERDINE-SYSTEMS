function tables = readWorkbookTables(filePath, config)
%READWORKBOOKTABLES Read all sheets in an Excel workbook into a struct.

sheetNames = sheetnames(filePath);
tables = struct();

for i = 1:numel(sheetNames)
    sheet = sheetNames{i};
    try
        options = detectImportOptions(filePath, 'Sheet', sheet, 'TextType', 'string');
        if config.PreserveVariableNames
            options.VariableNamingRule = 'preserve';
        end
        data = readtable(filePath, options);
    catch
        data = readtable(filePath, 'Sheet', sheet, ...
            'TextType', 'string', 'VariableNamingRule', 'preserve');
    end

    field = matlab.lang.makeValidName(sheet);
    if strlength(field) == 0
        field = sprintf('Sheet%d', i);
    end
    tables.(field) = data;
end
end
