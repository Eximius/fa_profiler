local NinePatch = import('/mods/profiler/lua/ui/controls/ninepatch.lua').NinePatch

-- Create a ninepatch using a texture path and naming convention, instead of explicitly with 9 images.
function CreateNinePatchStd(parent, texturePath)
    return NinePatch(parent,
        SkinnableFile(texturePath .. 'center.dds'),
        SkinnableFile(texturePath .. 'topLeft.dds'),
        SkinnableFile(texturePath .. 'topRight.dds'),
        SkinnableFile(texturePath .. 'bottomLeft.dds'),
        SkinnableFile(texturePath .. 'bottomRight.dds'),
        SkinnableFile(texturePath .. 'left.dds'),
        SkinnableFile(texturePath .. 'right.dds'),
        SkinnableFile(texturePath .. 'top.dds'),
        SkinnableFile(texturePath .. 'bottom.dds')
    )
end
