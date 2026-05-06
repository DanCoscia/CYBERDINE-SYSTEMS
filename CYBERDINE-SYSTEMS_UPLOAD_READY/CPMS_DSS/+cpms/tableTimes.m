function values = tableTimes(data, candidates)
%TABLETIMES Extract a datetime column, returning NaT when unavailable.

name = cpms.matchColumn(data, candidates);
if isempty(name)
    values = NaT(height(data), 1);
    return
end

raw = data.(name);
if isdatetime(raw)
    values = raw;
elseif isnumeric(raw)
    try
        values = datetime(raw, 'ConvertFrom', 'excel');
        plausible = year(values) >= 1990 & year(values) <= 2100;
        if any(~isnat(values)) && mean(plausible(~isnat(values))) < 0.5
            values = datetime(raw, 'ConvertFrom', 'datenum');
        end
    catch
        values = datetime(raw, 'ConvertFrom', 'datenum');
    end
else
    rawText = string(raw);
    rawText = rawText(:);
    values = NaT(numel(rawText), 1);
    valid = rawText ~= "" & ~ismissing(rawText) & lower(rawText) ~= "nan" & lower(rawText) ~= "nat";

    if any(valid)
        candidates = { ...
            '', ...
            'dd.MM.yyyy HH:mm:ss.SSSS', ...
            'dd.MM.yyyy HH:mm:ss.SSS', ...
            'dd.MM.yyyy HH:mm:ss', ...
            'yyyy-MM-dd HH:mm:ss', ...
            'yyyy-MM-dd HH:mm', ...
            'dd/MM/yyyy HH:mm:ss', ...
            'dd/MM/yyyy HH:mm', ...
            'MM/dd/yyyy HH:mm:ss', ...
            'MM/dd/yyyy HH:mm', ...
            'yyyy-MM-dd''T''HH:mm:ss', ...
            'yyyy-MM-dd''T''HH:mm:ss.SSS'};

        remaining = valid;
        for i = 1:numel(candidates)
            try
                if isempty(candidates{i})
                    parsed = datetime(rawText(remaining));
                else
                    parsed = datetime(rawText(remaining), 'InputFormat', candidates{i});
                end
                values(remaining) = parsed;
                break
            catch
            end
        end
    end
end
end
