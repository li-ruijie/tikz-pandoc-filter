--[[
Pandoc Lua filter to process TikZ environments into images.
Requires lualatex, Ghostscript, ImageMagick (magick), and dvisvgm in PATH.

Supports two syntaxes:

1. Raw LaTeX block (no attributes):
```{=latex}
\begin{tikzpicture}...\end{tikzpicture}
```

2. Code block with .tikz class (supports attributes):
```{.tikz width=80% caption="My diagram"}
\begin{tikzpicture}...\end{tikzpicture}
```

Output filenames:
- With caption: fig[%d%d]-[caption].png/.svg (caption truncated to 32 chars)
- Generates both PNG and SVG for each TikZ block

Caching:
- Image regenerates when source markdown's modification time changes
- After generation, image mtime is synced to source markdown mtime
]]

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local TIKZ_IMAGES_DIR = "tikz-images"
local FIGURE_ALIGNMENT = "center"           -- "center", "left", or "right"
local CAPTION_POSITION = "above"            -- "above" or "below"
local CAPTION_FIGURE_GAP = "1em"            -- spacing between caption and figure
local OUTPUT_FORMATS = "png,svg"            -- comma-separated: "png", "svg", or "png,svg"
local HTML_FORMAT = "svg"                   -- format used in HTML output: "png" or "svg"
local DOCX_FORMAT = "svg"                   -- format used in DOCX output: "png" or "svg"
local DOCX_FIGURE_STYLE = "Figure"          -- Word style for figure container (optional)

local figure_count = 0

-- OS Detection
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local DEV_NULL = IS_WINDOWS and "nul" or "/dev/null"

-- Cached Ghostscript command (found once, reused)
local ghostscript_cmd = nil

--------------------------------------------------------------------------------
-- Cross-platform helper functions
--------------------------------------------------------------------------------

local function has_format(fmt)
    return OUTPUT_FORMATS:match(fmt) ~= nil
end

local function shell_quote(s)
    if IS_WINDOWS then
        return '"' .. s:gsub('"', '""') .. '"'
    else
        return "'" .. s:gsub("'", "'\\''") .. "'"
    end
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function check_executable(cmd)
    if IS_WINDOWS then
        local handle = io.popen('where "' .. cmd .. '" 2>nul')
        if handle then
            local result = handle:read("*l")
            handle:close()
            if result and result ~= "" then
                return result
            end
        end
        if not cmd:match("%.exe$") then
            handle = io.popen('where "' .. cmd .. '.exe" 2>nul')
            if handle then
                local result = handle:read("*l")
                handle:close()
                if result and result ~= "" then
                    return result
                end
            end
        end
        return nil
    else
        local handle = io.popen('command -v "' .. cmd .. '" 2>/dev/null')
        if handle then
            local result = handle:read("*l")
            handle:close()
            if result and result ~= "" then
                return result
            end
        end
        return nil
    end
end

local function search_windows_registry()
    if not IS_WINDOWS then return nil end

    local function search_hive(hive_name)
        local handle = io.popen('reg query "' .. hive_name .. '\\SOFTWARE\\Ghostscript" 2>nul')
        if not handle then return nil end

        local versions = {}
        for line in handle:lines() do
            local ver_str = line:match("Ghostscript\\([%d%.]+)%s*$")
            if ver_str then
                local ver_num = tonumber(ver_str)
                if ver_num then
                    table.insert(versions, {str = ver_str, num = ver_num})
                end
            end
        end
        handle:close()

        table.sort(versions, function(a, b) return a.num > b.num end)

        for _, ver in ipairs(versions) do
            local key_path = hive_name .. "\\SOFTWARE\\Ghostscript\\" .. ver.str
            local qhandle = io.popen('reg query "' .. key_path .. '" /v GS_DLL 2>nul')
            if qhandle then
                for line in qhandle:lines() do
                    local dll_path = line:match("GS_DLL%s+REG_SZ%s+(.+)$")
                    if dll_path then
                        dll_path = dll_path:gsub("%s+$", "")
                        local exe_path = dll_path:gsub("gsdll%d*%.dll$", "")
                        if dll_path:find("gsdll64%.dll") then
                            exe_path = exe_path .. "gswin64c.exe"
                        else
                            exe_path = exe_path .. "gswin32c.exe"
                        end
                        local f = io.open(exe_path, "r")
                        if f then
                            f:close()
                            qhandle:close()
                            return exe_path
                        end
                    end
                end
                qhandle:close()
            end
        end
        return nil
    end

    local result = search_hive("HKLM")
    if result then return result end
    return search_hive("HKCU")
end

local function find_ghostscript()
    if ghostscript_cmd then return ghostscript_cmd end

    local candidates
    if IS_WINDOWS then
        candidates = {"gswin64c", "gswin32c", "mgs", "gs"}
    else
        candidates = {"gs", "gsc"}
    end

    for _, c in ipairs(candidates) do
        if check_executable(c) then
            ghostscript_cmd = c
            return ghostscript_cmd
        end
    end

    if IS_WINDOWS then
        local reg_cmd = search_windows_registry()
        if reg_cmd then
            ghostscript_cmd = reg_cmd
            return ghostscript_cmd
        end
    end

    ghostscript_cmd = candidates[1]
    return ghostscript_cmd
end

local function hex_encode(str)
    return (str:gsub('.', function(c)
        return string.format('%02X', string.byte(c))
    end))
end

local function get_mtime(path)
    if IS_WINDOWS then
        local escaped_path = path:gsub("\\", "/")
        local cmd = string.format(
            'powershell -NoProfile -c "(Get-Item -LiteralPath \\"%s\\").LastWriteTime.Ticks"',
            escaped_path
        )
        local handle = io.popen(cmd)
        if handle then
            local result = handle:read("*a")
            handle:close()
            return tonumber(result:match("%d+"))
        end
    else
        local handle = io.popen('stat -c %Y "' .. path .. '" 2>/dev/null')
        if handle then
            local result = handle:read("*a")
            handle:close()
            return tonumber(result:match("%d+"))
        end
    end
    return nil
end

local function set_mtime(target, source)
    if IS_WINDOWS then
        local escaped_target = target:gsub("\\", "/")
        local escaped_source = source:gsub("\\", "/")
        local cmd = string.format(
            'powershell -NoProfile -c "$t = (Get-Item -LiteralPath \\"%s\\").LastWriteTime; (Get-Item -LiteralPath \\"%s\\").LastWriteTime = $t"',
            escaped_source, escaped_target
        )
        os.execute(cmd)
    else
        os.execute('touch -r "' .. source .. '" "' .. target .. '"')
    end
end

--------------------------------------------------------------------------------
-- Embedded pdfcrop functionality (minimal version for single-page PDFs)
--------------------------------------------------------------------------------

local function pdfcrop(input_pdf, output_pdf)
    local gs_cmd = find_ghostscript()

    -- Create temp files in same directory as output
    local tmp_dir = output_pdf:match("(.+)[/\\]") or "."
    local tmp_base = tmp_dir .. "/tmp-pdfcrop-" .. os.time()
    local tmp_gsout = tmp_base .. ".gsout"
    local tmp_tex = tmp_base .. ".tex"
    local tmp_pdf = tmp_base .. ".pdf"
    local tmp_log = tmp_base .. ".log"

    -- Run Ghostscript to get bounding box
    local gs_args = string.format(
        '%s -sDEVICE=bbox -dBATCH -dNOPAUSE -c save pop -f %s > %s 2>&1',
        shell_quote(gs_cmd), shell_quote(input_pdf), shell_quote(tmp_gsout)
    )

    if IS_WINDOWS then
        os.execute('"' .. gs_args .. '"')
    else
        os.execute(gs_args)
    end

    -- Parse bounding box from Ghostscript output
    local bbox = nil
    local gs_out = io.open(tmp_gsout, "r")
    if gs_out then
        for line in gs_out:lines() do
            local x1, y1, x2, y2 = line:match("%%%%BoundingBox:%s*([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
            if x1 then
                bbox = {tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2)}
                break
            end
        end
        gs_out:close()
    end
    os.remove(tmp_gsout)

    if not bbox then
        io.stderr:write("pdfcrop: Failed to get bounding box from Ghostscript\n")
        return false
    end

    -- Generate TeX file for cropping
    local pdffilehex = hex_encode(input_pdf)
    local tex_content = string.format([[
\def\pdffilehex{%s}
\pdfvariable compresslevel=9
\outputmode=1
\pdfextension mapfile {}
\begingroup
\gdef\pdffile{}%%
\def\do#1#2{%%
\ifx\relax#2\relax
\ifx\relax#1\relax
\else
\errmessage{Invalid hex string}%%
\fi
\else
\lccode`0="#1#2\relax
\lowercase{\xdef\pdffile{\pdffile0}}%%
\expandafter\do
\fi
}%%
\expandafter\do\pdffilehex\relax\relax
\endgroup
\count0=1\relax
\setbox0=\hbox{%%
\saveimageresource page 1 mediabox{\pdffile}%%
\useimageresource\lastsavedimageresourceindex
}%%
\pdfvariable horigin=-%gbp\relax
\pdfvariable vorigin=%gbp\relax
\pagewidth=%gbp\relax
\advance\pagewidth by -%gbp\relax
\pageheight=%gbp\relax
\advance\pageheight by -%gbp\relax
\ht0=\pageheight
\shipout\box0\relax
\csname @@end\endcsname
\end
]], pdffilehex, bbox[1], bbox[2], bbox[3], bbox[1], bbox[4], bbox[2])

    local tex_file = io.open(tmp_tex, "w")
    if not tex_file then
        io.stderr:write("pdfcrop: Failed to create temp TeX file\n")
        return false
    end
    tex_file:write(tex_content)
    tex_file:close()

    -- Run LuaTeX to produce cropped PDF
    local tex_cmd = string.format(
        'luatex -no-shell-escape -interaction=batchmode %s > %s 2>&1',
        shell_quote(tmp_tex), DEV_NULL
    )

    -- Run from temp directory to avoid polluting working directory
    local old_dir = pandoc.system.get_working_directory()
    pandoc.system.with_working_directory(tmp_dir, function()
        local tex_basename = tmp_tex:match("([^/\\]+)$")
        local cmd = string.format(
            'luatex -no-shell-escape -interaction=batchmode %s > %s 2>&1',
            shell_quote(tex_basename), DEV_NULL
        )
        if IS_WINDOWS then
            os.execute('"' .. cmd .. '"')
        else
            os.execute(cmd)
        end
    end)

    -- Move result to output location
    os.remove(tmp_tex)
    os.remove(tmp_log)

    if file_exists(tmp_pdf) then
        os.remove(output_pdf)
        local ok = os.rename(tmp_pdf, output_pdf)
        if not ok then
            -- Fallback to copy if rename fails
            local f_in = io.open(tmp_pdf, "rb")
            local f_out = io.open(output_pdf, "wb")
            if f_in and f_out then
                f_out:write(f_in:read("*a"))
                f_in:close()
                f_out:close()
                os.remove(tmp_pdf)
                return true
            end
            if f_in then f_in:close() end
            if f_out then f_out:close() end
            return false
        end
        return true
    end

    io.stderr:write("pdfcrop: LuaTeX failed to produce output\n")
    return false
end

--------------------------------------------------------------------------------
-- TikZ processing functions
--------------------------------------------------------------------------------

local function sanitize_filename(str)
    local sanitized = str:gsub("%s+", "-")
                         :gsub("[^%w%-]", "")
                         :gsub("%-+", "-")
                         :gsub("^%-", "")
                         :gsub("%-$", "")
    return sanitized:lower()
end

local function make_basename(caption)
    figure_count = figure_count + 1
    local num = string.format("%02d", figure_count)

    local name_part = sanitize_filename(caption)
    if #name_part > 32 then
        name_part = name_part:sub(1, 32)
        name_part = name_part:gsub("%-$", "")
    end

    if name_part == "" then
        return string.format("fig%s", num)
    end

    return string.format("fig%s-%s", num, name_part)
end

local function needs_regeneration(outfile, source_file)
    if not file_exists(outfile) then
        io.stderr:write("  -> Image does not exist, regenerating\n")
        return true
    end
    local img_mtime = get_mtime(outfile)
    local src_mtime = get_mtime(source_file)
    if not img_mtime or not src_mtime then
        io.stderr:write("  -> Could not get mtime, regenerating\n")
        return true
    end
    if img_mtime ~= src_mtime then
        io.stderr:write(string.format("  -> mtime mismatch (img=%s, src=%s), regenerating\n", img_mtime, src_mtime))
        return true
    end
    return false
end

local function mkdir(path)
    pandoc.system.make_directory(path, true)
end

local function tikz2image(code, outfile_png, outfile_svg, source_file)
    local tex_content = [[
    \documentclass[border=0pt]{standalone}
    \usepackage{tikz}
    \usepackage{xcolor}
    \usetikzlibrary{trees, positioning, arrows.meta, shadows}
    \begin{document}
    ]] .. code .. [[

    \end{document}
    ]]

    pandoc.system.with_temporary_directory("tikz", function(tmpdir)
        local texfile = pandoc.path.join({tmpdir, "tikz.tex"})
        local pdffile = pandoc.path.join({tmpdir, "tikz.pdf"})

        -- Write tex file
        local f = io.open(texfile, "w")
        f:write(tex_content)
        f:close()

        -- Compile with lualatex
        pandoc.system.with_working_directory(tmpdir, function()
            local cmd = "lualatex -interaction=nonstopmode tikz.tex > " .. DEV_NULL .. " 2>&1"
            if IS_WINDOWS then
                os.execute('"' .. cmd .. '"')
            else
                os.execute(cmd)
            end
        end)

        -- Crop PDF using embedded pdfcrop
        local croppedfile = pandoc.path.join({tmpdir, "tikz-crop.pdf"})
        pdfcrop(pdffile, croppedfile)

        -- Convert to PNG and/or SVG based on OUTPUT_FORMATS setting
        local gen_png = has_format("png")
        local gen_svg = has_format("svg")

        if IS_WINDOWS then
            local cropped_fwd = croppedfile:gsub("\\", "/")
            local src_fwd = source_file:gsub("\\", "/")
            local ps_parts = {}

            if gen_png then
                local png_fwd = outfile_png:gsub("\\", "/")
                table.insert(ps_parts, string.format(
                    "$p1 = Start-Process -FilePath 'magick' -ArgumentList @('-density','300','%s','-trim','+repage','-quality','100','%s') -NoNewWindow -PassThru",
                    cropped_fwd, png_fwd))
                table.insert(ps_parts, "if($p1){$p1.WaitForExit()}")
                table.insert(ps_parts, string.format(
                    "(Get-Item -LiteralPath '%s').LastWriteTime = (Get-Item -LiteralPath '%s').LastWriteTime",
                    png_fwd, src_fwd))
            end

            if gen_svg then
                local svg_fwd = outfile_svg:gsub("\\", "/")
                table.insert(ps_parts, string.format(
                    "$p2 = Start-Process -FilePath 'dvisvgm' -ArgumentList @('--pdf','--exact-bbox','--no-fonts','%s','-o','%s') -NoNewWindow -PassThru",
                    cropped_fwd, svg_fwd))
                table.insert(ps_parts, "if($p2){$p2.WaitForExit()}")
                table.insert(ps_parts, string.format(
                    "(Get-Item -LiteralPath '%s').LastWriteTime = (Get-Item -LiteralPath '%s').LastWriteTime",
                    svg_fwd, src_fwd))
            end

            local ps_script = table.concat(ps_parts, "; ")
            local ps_cmd = 'powershell -NoProfile -Command "' .. ps_script .. '"'
            os.execute('"' .. ps_cmd .. '"')
        else
            local cmds = {}
            local touch_files = {}

            if gen_png then
                table.insert(cmds, string.format(
                    'magick -density 300 %s -trim +repage -quality 100 %s',
                    shell_quote(croppedfile), shell_quote(outfile_png)))
                table.insert(touch_files, shell_quote(outfile_png))
            end

            if gen_svg then
                table.insert(cmds, string.format(
                    'dvisvgm --pdf --exact-bbox --no-fonts %s -o %s > /dev/null 2>&1',
                    shell_quote(croppedfile), shell_quote(outfile_svg)))
                table.insert(touch_files, shell_quote(outfile_svg))
            end

            local parallel_cmd = string.format(
                '(%s & wait) && touch -r %s %s',
                table.concat(cmds, " & "),
                shell_quote(source_file), table.concat(touch_files, " ")
            )
            os.execute(parallel_cmd)
        end
    end)
end

local function process_tikz(code, el)
    local caption = ""
    local label = ""
    if el and el.attributes then
        caption = el.attributes["caption"] or ""
        label = el.attributes["label"] or ""
    end

    local basename = make_basename(caption)
    local outfile_png = pandoc.path.join({TIKZ_IMAGES_DIR, basename .. ".png"})
    local outfile_svg = pandoc.path.join({TIKZ_IMAGES_DIR, basename .. ".svg"})

    local source_file = PANDOC_STATE.input_files[1]

    mkdir(TIKZ_IMAGES_DIR)

    -- Check regeneration based on primary output format
    local check_file = has_format("svg") and outfile_svg or outfile_png
    if needs_regeneration(check_file, source_file) then
        io.stderr:write("Generating TikZ image: " .. basename .. " (" .. OUTPUT_FORMATS .. ")\n")
        tikz2image(code, outfile_png, outfile_svg, source_file)
    end

    -- Detect output format and select appropriate image format
    local is_docx = FORMAT == "docx"
    local display_format = is_docx and DOCX_FORMAT or HTML_FORMAT
    local outfile = (display_format == "png") and outfile_png or outfile_svg

    -- Get optional width/height attributes
    local width = el and el.attributes and el.attributes["width"]
    local height = el and el.attributes and el.attributes["height"]

    local caption_inlines = caption ~= "" and {pandoc.Str(caption)} or {}

    if is_docx then
        -- DOCX output: use pandoc attributes instead of CSS
        local img_attrs = {}
        if width then table.insert(img_attrs, {"width", width}) end
        if height then table.insert(img_attrs, {"height", height}) end
        local img_attr = pandoc.Attr("", {}, img_attrs)
        local img = pandoc.Image(caption_inlines, outfile, caption, img_attr)

        -- Build content with caption in configured position
        local content = {}
        local caption_para = caption ~= "" and pandoc.Para({pandoc.Emph({pandoc.Str(caption)})}) or nil
        local img_para = pandoc.Para({img})

        if CAPTION_POSITION == "above" and caption_para then
            table.insert(content, caption_para)
        end
        table.insert(content, img_para)
        if CAPTION_POSITION ~= "above" and caption_para then
            table.insert(content, caption_para)
        end

        -- Wrap in Div with custom Word style for alignment
        local div_attrs = {{"custom-style", DOCX_FIGURE_STYLE}}
        local div_attr = pandoc.Attr(label, {}, div_attrs)
        return pandoc.Div(content, div_attr)
    else
        -- HTML output: use CSS styling
        local img_margin
        if FIGURE_ALIGNMENT == "center" then
            img_margin = "0 auto"
        elseif FIGURE_ALIGNMENT == "right" then
            img_margin = "0 0 0 auto"
        else
            img_margin = "0 auto 0 0"
        end
        local img_style = "display:block; margin:" .. img_margin

        if width then
            img_style = img_style .. "; width:" .. width
        end
        if height then
            img_style = img_style .. "; height:" .. height
        end

        local img_attr = pandoc.Attr("", {}, {{"style", img_style}})
        local img = pandoc.Image(caption_inlines, outfile, caption, img_attr)

        -- Build figure style based on configuration
        local flex_direction = CAPTION_POSITION == "above" and "column-reverse" or "column"
        local fig_style = string.format(
            "text-align:%s; display:flex; flex-direction:%s; align-items:%s; gap:%s",
            FIGURE_ALIGNMENT, flex_direction, FIGURE_ALIGNMENT, CAPTION_FIGURE_GAP
        )
        local fig_attr = pandoc.Attr(label, {}, {{"style", fig_style}})
        local caption_block = pandoc.Plain(caption_inlines)
        return pandoc.Figure({pandoc.Plain({img})}, {caption_block}, fig_attr)
    end
end

-- Handle raw LaTeX blocks
function RawBlock(el)
    if el.format ~= "latex" then
        return nil
    end
    if not el.text:match("\\begin{tikzpicture}") then
        return nil
    end
    return process_tikz(el.text, nil)
end

-- Handle code blocks with .tikz class
function CodeBlock(el)
    if not el.classes:includes("tikz") then
        return nil
    end
    return process_tikz(el.text, el)
end
