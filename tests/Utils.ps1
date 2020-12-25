Function PSObjectToHashtable([parameter(ValueFromPipeline)]$psobject)
{
    $psobject.psobject.properties | % { $ht = @{} } { $ht[$_.Name] = $_.Value } { $ht }
}

Function AssertArraysEqual([array]$expected, $actual, [string]$path=$null)
{
    $actual -is [array] | Should -BeTrue -Because "expected array for path $path"
    $actual.Count | Should -Be $expected.Count -Because "expected array for $path has that many items"

    0..($actual.Count - 1) | % {
        $a = $actual[$_]
        $e = $expected[$_]

        $currentPath = if ($path) { "$path[$_]" } else { "[$_]" }

        if ($e -is [hashtable]) 
        {
            AssertHashtablesEqual $e $a $currentPath
        }
        elseif ($e -is [array])
        {
            AssertArraysEqual $e $a $currentPath
        }
        else
        {
            $a | Should -Be $e -Because "of expected value of $currentPath"
        } 
    }
}

Function AssertHashtablesEqual([hashtable]$expected, $actual, [string]$path=$null)
{
    if ($actual -is [pscustomobject])
    {
        $actual = $actual | PSObjectToHashtable
    }
    $actual -is [hashtable] | Should -BeTrue -Because "expected hashtable for path $path"

    $actual.Keys | where { $null -ne $actual.$_ } | % {
        $_ | Should -BeIn $expected.Keys -Because "key was in actual keys of path $path"
    }

    $expected.Keys | where { $null -ne $expected.$_ } | % {
        $_ | Should -BeIn $actual.Keys -Because "key was in expected keys of path $path"
    }

    $actual.Keys | % { 
        $a = $actual.$_
        $e = $expected.$_

        $currentPath = if ($path) { "$path.$_" } else { "$_" }

        if ($e -is [hashtable]) 
        {
            AssertHashtablesEqual $e $a $currentPath
        }
        elseif ($e -is [array])
        {
            AssertArraysEqual $e $a $currentPath
        }
        else
        {
            $a | Should -Be $e -Because "of expected value of $currentPath"
        }        
    }
}