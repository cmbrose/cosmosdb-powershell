Function PSObjectToHashtable([parameter(ValueFromPipeline)]$psobject)
{
    $psobject.psobject.properties | % { $ht = @{} } { $ht[$_.Name] = $_.Value } { $ht }
}

Function AssertHashtablesEqual([hashtable]$expected, [hashtable]$actual)
{
    $actual.Keys.Count | Should Be $expected.Keys.Count

    $actual.Keys | % { 
        $a = $actual.$_
        $e = $expected.$_

        (!!$a) | Should Be (!!$e)

        if ($e -is [hashtable]) 
        {
            ($a -is [pscustomobject]) | Should Be $true
            AssertHashtablesEqual $e ($a  | PSObjectToHashtable)
        }
        else
        {
            $a | Should Be $e
        }        
    }
}