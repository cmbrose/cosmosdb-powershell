Function PSObjectToHashtable([parameter(ValueFromPipeline)]$psobject)
{
    $psobject.psobject.properties | % { $ht = @{} } { $ht[$_.Name] = $_.Value } { $ht }
}

Function AssertHashtablesEqual([hashtable]$expected, [hashtable]$actual, [string]$path=$null)
{
    $actual.Keys | % {
        $_ | Should -BeIn $expected.Keys -Because "key was in actual keys of path $path"
    }

    $expected.Keys | % {
        $_ | Should -BeIn $actual.Keys -Because "key was in expected keys of path $path"
    }

    $actual.Keys | % { 
        $a = $actual.$_
        $e = $expected.$_

        $currentPath = if ($path) { "$path.$_" } else { "$_" }

        if ($null -eq $e)
        {
            $a | Should -BeNullOrEmpty -Because "expected value of $currentPath is null"
        }
        else
        {
            $a | Should -Not -BeNullOrEmpty -Because "expected value of $currentPath is not null"
        }           

        if ($e -is [hashtable]) 
        {
            if ($a -is [pscustomobject])
            {
                $a = $a | PSObjectToHashtable
            }

            $a -is [hashtable] | Should -Be $true
            AssertHashtablesEqual $e $a $currentPath
        }
        else
        {
            $a | Should -Be $e -Because "of expected value of $currentPath"
        }        
    }
}