$a=@($args)
if($a.Count -ge 2 -and $a[0] -eq '-s'){$a=$a[2..($a.Count-1)]}
if($a.Count -gt 0 -and $a[0] -eq 'devices'){
    'List of devices attached'
    exit 0
}
exit 0
