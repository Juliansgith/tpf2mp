# Shared WinForms theme for the TPF2MP launcher and world lobby.
# Dot-source after loading System.Windows.Forms and System.Drawing.
# One palette, one type scale, and constructors for the few control kinds the
# dialogs use, so both windows read as one product. Windows PowerShell 5.1.

$script:Tpf2mpTheme = @{
    Bg          = [Drawing.Color]::FromArgb(15, 19, 24)     # window
    Surface     = [Drawing.Color]::FromArgb(23, 29, 36)     # card
    SurfaceAlt  = [Drawing.Color]::FromArgb(30, 38, 47)     # nested/secondary surface
    Border      = [Drawing.Color]::FromArgb(43, 54, 66)
    Field       = [Drawing.Color]::FromArgb(11, 15, 19)
    FieldBorder = [Drawing.Color]::FromArgb(52, 65, 79)
    Text        = [Drawing.Color]::FromArgb(233, 238, 243)
    Muted       = [Drawing.Color]::FromArgb(140, 154, 168)
    Faint       = [Drawing.Color]::FromArgb(96, 108, 120)
    Accent      = [Drawing.Color]::FromArgb(45, 190, 168)   # teal
    AccentHover = [Drawing.Color]::FromArgb(70, 210, 188)
    AccentText  = [Drawing.Color]::FromArgb(6, 24, 22)
    Secondary   = [Drawing.Color]::FromArgb(36, 46, 57)
    SecondaryHover = [Drawing.Color]::FromArgb(48, 60, 73)
    Success     = [Drawing.Color]::FromArgb(74, 199, 128)
    Warning     = [Drawing.Color]::FromArgb(235, 181, 71)
    Danger      = [Drawing.Color]::FromArgb(236, 96, 96)
    Info        = [Drawing.Color]::FromArgb(92, 168, 230)
    LogBg       = [Drawing.Color]::FromArgb(10, 13, 17)
    LogText     = [Drawing.Color]::FromArgb(178, 196, 208)
    Disabled    = [Drawing.Color]::FromArgb(80, 92, 104)
}
$script:Tpf2mpFonts = @{
    Base    = [Drawing.Font]::new('Segoe UI', 10)
    Small   = [Drawing.Font]::new('Segoe UI', 9)
    Title   = [Drawing.Font]::new('Segoe UI Semibold', 19)
    Heading = [Drawing.Font]::new('Segoe UI Semibold', 11.5)
    Section = [Drawing.Font]::new('Segoe UI Semibold', 8.5)
    Button  = [Drawing.Font]::new('Segoe UI Semibold', 9.5)
    Mono    = [Drawing.Font]::new('Cascadia Mono', 9)
}

function Get-Tpf2mpTheme { $script:Tpf2mpTheme }
function Get-Tpf2mpFonts { $script:Tpf2mpFonts }

function Set-Tpf2mpFormStyle($Form, [string]$Title) {
    $Form.Text = $Title
    $Form.BackColor = $script:Tpf2mpTheme.Bg
    $Form.ForeColor = $script:Tpf2mpTheme.Text
    $Form.Font = $script:Tpf2mpFonts.Base
    $Form.StartPosition = 'CenterScreen'
    $Form.AutoScaleMode = 'None'
}

# A card: flat surface with a hairline border and an optional uppercase
# section heading. Controls are added to the returned panel.
function New-Tpf2mpCard($Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height, [string]$Heading, $Color) {
    $panel = New-Object Windows.Forms.Panel
    $panel.SetBounds($X, $Y, $Width, $Height)
    $panel.BackColor = if ($Color) { $Color } else { $script:Tpf2mpTheme.Surface }
    $border = $script:Tpf2mpTheme.Border
    $panel.Add_Paint({
        param($sender, $e)
        $pen = New-Object Drawing.Pen($border)
        $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1)
        $pen.Dispose()
    }.GetNewClosure())
    if ($Heading) {
        $label = New-Object Windows.Forms.Label
        $label.Text = $Heading.ToUpperInvariant()
        $label.Font = $script:Tpf2mpFonts.Section
        $label.ForeColor = $script:Tpf2mpTheme.Muted
        $label.BackColor = [Drawing.Color]::Transparent
        $label.SetBounds(18, 12, $Width - 36, 18)
        $panel.Controls.Add($label)
    }
    $Parent.Controls.Add($panel)
    return $panel
}

function New-Tpf2mpLabel($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 22,
    [ValidateSet('Body', 'Muted', 'Faint', 'Heading', 'Title', 'Section')][string]$Kind = 'Body') {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.SetBounds($X, $Y, $Width, $Height)
    $label.BackColor = [Drawing.Color]::Transparent
    switch ($Kind) {
        'Muted'   { $label.ForeColor = $script:Tpf2mpTheme.Muted; $label.Font = $script:Tpf2mpFonts.Small }
        'Faint'   { $label.ForeColor = $script:Tpf2mpTheme.Faint; $label.Font = $script:Tpf2mpFonts.Small }
        'Heading' { $label.ForeColor = $script:Tpf2mpTheme.Text; $label.Font = $script:Tpf2mpFonts.Heading }
        'Title'   { $label.ForeColor = $script:Tpf2mpTheme.Text; $label.Font = $script:Tpf2mpFonts.Title }
        'Section' { $label.ForeColor = $script:Tpf2mpTheme.Muted; $label.Font = $script:Tpf2mpFonts.Section; $label.Text = $Text.ToUpperInvariant() }
        default   { $label.ForeColor = $script:Tpf2mpTheme.Text; $label.Font = $script:Tpf2mpFonts.Base }
    }
    $Parent.Controls.Add($label)
    return $label
}

# Buttons: Primary (filled accent), Secondary (raised surface), Ghost (border
# only) and Danger. Sentence case text, hover feedback, consistent height.
function New-Tpf2mpButton($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 36,
    [ValidateSet('Primary', 'Secondary', 'Ghost', 'Danger')][string]$Kind = 'Secondary') {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.SetBounds($X, $Y, $Width, $Height)
    $button.FlatStyle = 'Flat'
    $button.UseVisualStyleBackColor = $false
    $button.Font = $script:Tpf2mpFonts.Button
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    $button.TextAlign = 'MiddleCenter'
    $button.FlatAppearance.BorderSize = 1
    Set-Tpf2mpButtonKind $button $Kind
    # Registered once per button: re-applying the kind must not stack handlers.
    $button.Add_EnabledChanged({
        param($sender, $e)
        Set-Tpf2mpButtonKind $sender ([string]$sender.Tag)
    })
    $Parent.Controls.Add($button)
    return $button
}

function Set-Tpf2mpButtonKind($Button, [string]$Kind) {
    $theme = $script:Tpf2mpTheme
    switch ($Kind) {
        'Primary' { $back = $theme.Accent; $hover = $theme.AccentHover; $fore = $theme.AccentText; $border = $theme.Accent }
        'Ghost'   { $back = $theme.Surface; $hover = $theme.SurfaceAlt; $fore = $theme.Text; $border = $theme.FieldBorder }
        'Danger'  { $back = $theme.Surface; $hover = [Drawing.Color]::FromArgb(74, 32, 36); $fore = $theme.Danger; $border = [Drawing.Color]::FromArgb(110, 48, 52) }
        default   { $back = $theme.Secondary; $hover = $theme.SecondaryHover; $fore = $theme.Text; $border = $theme.Secondary }
    }
    $Button.Tag = $Kind
    if ($Button.Enabled) {
        $Button.BackColor = $back
        $Button.ForeColor = $fore
        $Button.FlatAppearance.BorderColor = $border
    }
    else {
        $Button.BackColor = $theme.Surface
        $Button.ForeColor = $theme.Disabled
        $Button.FlatAppearance.BorderColor = $theme.Border
    }
    $Button.FlatAppearance.MouseOverBackColor = $hover
    $Button.FlatAppearance.MouseDownBackColor = $hover
}

# Text input inside a hairline field frame so every box has the same look.
function New-Tpf2mpTextBox($Parent, [string]$Value, [int]$X, [int]$Y, [int]$Width, [int]$Height = 32) {
    $frame = New-Object Windows.Forms.Panel
    $frame.SetBounds($X, $Y, $Width, $Height)
    $frame.BackColor = $script:Tpf2mpTheme.Field
    $border = $script:Tpf2mpTheme.FieldBorder
    $frame.Add_Paint({
        param($sender, $e)
        $pen = New-Object Drawing.Pen($border)
        $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1)
        $pen.Dispose()
    }.GetNewClosure())
    $box = New-Object Windows.Forms.TextBox
    $box.Text = $Value
    $box.BorderStyle = 'None'
    $box.BackColor = $script:Tpf2mpTheme.Field
    $box.ForeColor = $script:Tpf2mpTheme.Text
    $box.Font = $script:Tpf2mpFonts.Base
    $box.SetBounds(10, [int](($Height - 19) / 2), $Width - 20, 19)
    $frame.Controls.Add($box)
    $Parent.Controls.Add($frame)
    $box | Add-Member -NotePropertyName Frame -NotePropertyValue $frame -Force
    return $box
}

# The system combo box paints light flat chrome that no colour property
# overrides, so it is owner-drawn and overhangs a hairline field frame by three
# pixels on every edge plus the drop-down button's width, where the chrome is
# clipped away. Clicks still land on the combo box, which draws its own chevron.
$script:Tpf2mpComboPainter = {
    param($sender, $e)
    $colors = $script:Tpf2mpTheme
    $isEdit = ($e.State -band [Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0
    $isHot = (-not $isEdit) -and (($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0)
    $fill = New-Object Drawing.SolidBrush($(if ($isHot) { $colors.SurfaceAlt } else { $colors.Field }))
    if ($isEdit) { $e.Graphics.FillRectangle($fill, 0, 0, $sender.Width, $sender.Height) }
    else { $e.Graphics.FillRectangle($fill, $e.Bounds) }
    $fill.Dispose()
    $color = if ($sender.Enabled) { $colors.Text } else { $colors.Disabled }
    if ($e.Index -ge 0) {
        $bounds = [Drawing.Rectangle]::new(($e.Bounds.X + 8), $e.Bounds.Y,
            ($e.Bounds.Width - 10), $e.Bounds.Height)
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$sender.Items[$e.Index],
            $sender.Font, $bounds, $color,
            ([Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis))
    }
    if ($isEdit -and $sender.Parent) {
        $arrow = New-Object Drawing.SolidBrush($(if ($sender.Enabled) { $colors.Muted } else { $colors.Disabled }))
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $x = $sender.Parent.ClientSize.Width - $sender.Left - 14
        $y = [int]($sender.Height / 2)
        $e.Graphics.FillPolygon($arrow, @([Drawing.Point]::new(($x - 4), ($y - 2)),
            [Drawing.Point]::new(($x + 4), ($y - 2)), [Drawing.Point]::new($x, ($y + 3))))
        $arrow.Dispose()
    }
}

function New-Tpf2mpComboBox($Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height = 32) {
    $frame = New-Object Windows.Forms.Panel
    $frame.SetBounds($X, $Y, $Width, $Height)
    $frame.BackColor = $script:Tpf2mpTheme.Field
    $border = $script:Tpf2mpTheme.FieldBorder
    $frame.Add_Paint({
        param($sender, $e)
        $pen = New-Object Drawing.Pen($border)
        $e.Graphics.DrawRectangle($pen, 0, 0, ($sender.Width - 1), ($sender.Height - 1))
        $pen.Dispose()
    }.GetNewClosure())
    $combo = New-Object Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.FlatStyle = 'Flat'
    $combo.DrawMode = 'OwnerDrawFixed'
    $combo.ItemHeight = $Height
    $combo.Font = $script:Tpf2mpFonts.Base
    $combo.BackColor = $script:Tpf2mpTheme.Field
    $combo.ForeColor = $script:Tpf2mpTheme.Text
    $combo.SetBounds(-3, -3, ($Width + 28), ($Height + 6))
    $combo.Add_DrawItem($script:Tpf2mpComboPainter)
    $frame.Controls.Add($combo)
    $Parent.Controls.Add($frame)
    $combo | Add-Member -NotePropertyName Frame -NotePropertyValue $frame -Force
    return $combo
}

function New-Tpf2mpCheckBox($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 24) {
    $check = New-Object Windows.Forms.CheckBox
    $check.Text = $Text
    $check.SetBounds($X, $Y, $Width, $Height)
    $check.ForeColor = $script:Tpf2mpTheme.Text
    $check.BackColor = [Drawing.Color]::Transparent
    $check.Font = $script:Tpf2mpFonts.Base
    $check.Cursor = [Windows.Forms.Cursors]::Hand
    $Parent.Controls.Add($check)
    return $check
}

# A status pill: small rounded label whose colour names the state.
function New-Tpf2mpPill($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 24) {
    $pill = New-Object Windows.Forms.Label
    $pill.Text = $Text
    $pill.SetBounds($X, $Y, $Width, $Height)
    $pill.TextAlign = 'MiddleCenter'
    $pill.Font = $script:Tpf2mpFonts.Section
    $pill.BackColor = [Drawing.Color]::Transparent
    $pill | Add-Member -NotePropertyName PillColor -NotePropertyValue $script:Tpf2mpTheme.Muted -Force
    $pill.Add_Paint({
        param($sender, $e)
        # Label paints its own text before this handler runs; repaint the parent
        # surface first so the pill shows one centred caption, not two.
        if ($sender.Parent) { $e.Graphics.Clear($sender.Parent.BackColor) }
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $color = $sender.PillColor
        $fill = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(38, $color))
        $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(140, $color))
        # The comma operator binds tighter than subtraction, so each argument
        # needs its own parentheses or New-Object receives an array to subtract.
        $rect = New-Object Drawing.Rectangle(0, 0, ($sender.Width - 1), ($sender.Height - 1))
        $path = New-Object Drawing.Drawing2D.GraphicsPath
        $radius = $rect.Height
        $path.AddArc($rect.X, $rect.Y, $radius, $radius, 180, 90)
        $path.AddArc($rect.Right - $radius, $rect.Y, $radius, $radius, 270, 90)
        $path.AddArc($rect.Right - $radius, $rect.Bottom - $radius, $radius, $radius, 0, 90)
        $path.AddArc($rect.X, $rect.Bottom - $radius, $radius, $radius, 90, 90)
        $path.CloseFigure()
        $e.Graphics.FillPath($fill, $path)
        $e.Graphics.DrawPath($pen, $path)
        $format = New-Object Drawing.StringFormat
        $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
        $textBrush = New-Object Drawing.SolidBrush($color)
        $e.Graphics.DrawString($sender.Text.ToUpperInvariant(), $sender.Font, $textBrush, [Drawing.RectangleF]::new(0, 0, $sender.Width, $sender.Height), $format)
        $fill.Dispose(); $pen.Dispose(); $textBrush.Dispose(); $path.Dispose(); $format.Dispose()
    })
    $Parent.Controls.Add($pill)
    return $pill
}

function Set-Tpf2mpPill($Pill, [string]$Text, [ValidateSet('Muted', 'Accent', 'Success', 'Warning', 'Danger', 'Info')][string]$State = 'Muted') {
    $Pill.PillColor = $script:Tpf2mpTheme[$State]
    if ($Pill.Text -cne $Text) { $Pill.Text = $Text }
    $Pill.Invalidate()
}

# Owner-drawn tabs: flat strip, accent underline on the selected page.
function Set-Tpf2mpTabStyle($Tabs) {
    $Tabs.DrawMode = 'OwnerDrawFixed'
    $Tabs.SizeMode = 'Fixed'
    $Tabs.ItemSize = New-Object Drawing.Size(132, 36)
    $Tabs.Appearance = 'Normal'
    $Tabs.Font = $script:Tpf2mpFonts.Button
    $Tabs.Add_DrawItem({
        param($sender, $e)
        $theme = $script:Tpf2mpTheme
        $page = $sender.TabPages[$e.Index]
        $selected = $sender.SelectedIndex -eq $e.Index
        $rect = $e.Bounds
        $back = New-Object Drawing.SolidBrush($theme.Surface)
        $e.Graphics.FillRectangle($back, $rect)
        if ($selected) {
            $line = New-Object Drawing.SolidBrush($theme.Accent)
            $e.Graphics.FillRectangle($line, $rect.X + 8, $rect.Bottom - 5, $rect.Width - 16, 3)
            $line.Dispose()
        }
        $format = New-Object Drawing.StringFormat
        $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
        $brush = New-Object Drawing.SolidBrush($(if ($selected) { $theme.Text } else { $theme.Muted }))
        $e.Graphics.DrawString($page.Text, $sender.Font, $brush, [Drawing.RectangleF]::new($rect.X, $rect.Y, $rect.Width, $rect.Height), $format)
        $back.Dispose(); $brush.Dispose(); $format.Dispose()
    })
    # Visual styles still draw a light pane border and a light frame around each
    # tab item underneath the owner-drawn content. A window region that keeps
    # only the flat interiors and the page removes that chrome, so the strip
    # reads as part of the card it sits on.
    $clip = {
        param($sender, $e)
        if (-not $sender.IsHandleCreated -or $sender.TabPages.Count -eq 0) { return }
        $region = New-Object Drawing.Region([Drawing.Rectangle]::new(0, 0, 0, 0))
        for ($index = 0; $index -lt $sender.TabPages.Count; $index++) {
            $item = $sender.GetTabRect($index)
            $region.Union([Drawing.Rectangle]::new(($item.X + 2), ($item.Y + 2), ($item.Width - 4), ($item.Height - 4)))
        }
        $page = $sender.DisplayRectangle
        $region.Union([Drawing.Rectangle]::new($page.X, $page.Y, $page.Width, $page.Height))
        $sender.Region = $region
    }
    $Tabs.Add_HandleCreated($clip)
    $Tabs.Add_Layout($clip)
    foreach ($page in $Tabs.TabPages) {
        $page.BackColor = $script:Tpf2mpTheme.Surface
        $page.ForeColor = $script:Tpf2mpTheme.Text
        $page.BorderStyle = 'None'
        $page.Padding = New-Object Windows.Forms.Padding(0)
    }
}

function New-Tpf2mpLogBox($Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $box = New-Object Windows.Forms.TextBox
    $box.SetBounds($X, $Y, $Width, $Height)
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'Vertical'
    $box.BorderStyle = 'FixedSingle'
    $box.BackColor = $script:Tpf2mpTheme.LogBg
    $box.ForeColor = $script:Tpf2mpTheme.LogText
    $box.Font = $script:Tpf2mpFonts.Mono
    $Parent.Controls.Add($box)
    return $box
}

# A thin horizontal rule between groups inside a card.
function New-Tpf2mpRule($Parent, [int]$X, [int]$Y, [int]$Width) {
    $rule = New-Object Windows.Forms.Panel
    $rule.SetBounds($X, $Y, $Width, 1)
    $rule.BackColor = $script:Tpf2mpTheme.Border
    $Parent.Controls.Add($rule)
    return $rule
}
