# Test PSCustomObject property mutability
$obj = [PSCustomObject]@{ Name = "test"; Items = @() }
Write-Output "Initial Items: $($obj.Items.Count)"

# Try reassignment
try {
    $obj.Items = @(1, 2, 3)
    Write-Output "After reassign Items: $($obj.Items.Count)"
} catch {
    Write-Output "Reassign failed: $_"
}

# Try .Add() if ArrayList
$alt = [System.Collections.ArrayList]::new()
$alt.Add(1) | Out-Null
$obj2 = [PSCustomObject]@{ Name = "test2"; Items2 = $alt }
Write-Output "ArrayList Items2: $($obj2.Items2.Count)"
try {
    $obj2.Items2.Add(2) | Out-Null
    Write-Output "After .Add() Items2: $($obj2.Items2.Count)"
} catch {
    Write-Output ".Add() on ArrayList failed: $_"
}

# Try PSObject property access
try {
    $obj.PSObject.Properties['Items'].Value = @(4, 5, 6)
    Write-Output "After PSObject set Items: $($obj.Items.Count)"
} catch {
    Write-Output "PSObject set failed: $_"
}

Write-Output "PSVersion: $($PSVersionTable.PSVersion)"
