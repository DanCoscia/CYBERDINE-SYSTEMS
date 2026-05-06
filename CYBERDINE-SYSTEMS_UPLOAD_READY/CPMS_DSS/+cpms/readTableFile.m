function data = readTableFile(filePath, config)
%READTABLEFILE Read a delimited or spreadsheet table while preserving names.

try
    options = detectImportOptions(filePath, 'TextType', 'string');
    if config.PreserveVariableNames
        options.VariableNamingRule = 'preserve';
    end
    data = readtable(filePath, options);
catch
    data = readtable(filePath, 'TextType', 'string', 'VariableNamingRule', 'preserve');
end
end
