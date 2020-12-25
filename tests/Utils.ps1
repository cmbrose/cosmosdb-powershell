Function PSObjectToHashtable([parameter(ValueFromPipeline)]$psobject)
{
    $psobject.psobject.properties | % { $ht = @{} } { $ht[$_.Name] = $_.Value } { $ht }
}

Function AssertObjectsEqual($expected, $actual, [string]$path=$null)
{
    if ($expected -is [hashtable]) 
    {
        AssertHashtablesEqual $expected $actual $path
    }
    elseif ($expected -is [array])
    {
        AssertArraysEqual $expected $actual $path
    }
    else
    {
        AssertValuesEqual $expected $actual $path
    } 
}

Function AssertValuesEqual($expected, $actual, [string]$path=$null)
{
    $actual | Should -Be $expected -Because "of expected value of $path"
}

Function AssertArraysEqual([array]$expected, $actual, [string]$path=$null)
{
    $actual -is [array] | Should -BeTrue -Because "the expected value for $path is an array"
    $actual.Count | Should -Be $expected.Count -Because "the expected array for $path has that many items"

    0..($actual.Count - 1) | % {
        $a = $actual[$_]
        $e = $expected[$_]

        $currentPath = if ($path) { "$path[$_]" } else { "[$_]" }

        AssertObjectsEqual $e $a $currentPath
    }
}

Function AssertHashtablesEqual([hashtable]$expected, $actual, [string]$path=$null)
{
    if ($actual -is [pscustomobject])
    {
        $actual = $actual | PSObjectToHashtable
    }

    $actual -is [hashtable] | Should -BeTrue -Because "the expected value for $path is a hashtable"

    $actual.Keys | where { $null -ne $actual.$_ } | % {
        $_ | Should -BeIn $expected.Keys -Because "it was in actual keys of $path"
    }

    $expected.Keys | where { $null -ne $expected.$_ } | % {
        $_ | Should -BeIn $actual.Keys -Because "it was in expected keys of $path"
    }

    $actual.Keys | % { 
        $a = $actual.$_
        $e = $expected.$_

        $currentPath = if ($path) { "$path.$_" } else { "$_" }

        AssertObjectsEqual $e $a $currentPath      
    }
}