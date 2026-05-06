function out = mergeStruct(base, overrides)
%MERGESTRUCT Merge scalar structs, preserving fields not overridden.

out = base;
fields = fieldnames(overrides);
for i = 1:numel(fields)
    name = fields{i};
    if isstruct(overrides.(name)) && isfield(out, name) && isstruct(out.(name))
        out.(name) = cpms.mergeStruct(out.(name), overrides.(name));
    else
        out.(name) = overrides.(name);
    end
end
end
