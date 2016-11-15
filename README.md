PSUltraDNS Module
=================

Initial work on a UltraDNS API client framework. 

## Getting Started

To get started, you will first need to import the module.  You can download the module locally and then execute:

```powershell
Import-Module PSUltraDNS
```


## Usage

 * Right now, only basic REST API features have been implemented. 

### Sample Usage

```powershell
# If ApiHost parameter is omitted, restapi.ultradns.com API endpoint will be used.
$client = New-UltraDnsClient -Credential vrimkus -ApiHost test-restapi.ultradns.com

# list resource record sets (rrsets), of any type, for mysite.com Zone (default limit of 100).
$client.Zone('mysite.com').RRSet()

# list the CNAME resource record sets.
$client.Zone('mysite.com').RRSet('CNAME')

# list rrsets using a query, targeting owner 'hosting'.
$client.Zone('mysite.com').RRSet('ANY', @{ q = "owner:hosting"})

# create an A record, origin-fake.mysite.com, pointed to 37.244.69.167, with TTL of 300.
$client.Zone('mysite.com').CreateRRSet('A', 'origin-fake', '37.244.69.167', 300)
```

## Future
 * Finish building out C# Cmdlet
 * Account functionality
 * Zone Creation & Deletion
 * RRSet Update & Deletion
 * Beyond...