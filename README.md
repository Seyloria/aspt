
## aspt - aerynOS | Solus package tool

``` 
     ▄▄▄   ▄▄▄▄ ▄▄▄▄ ▄▄▄▄▄▄ 
    ██▀██ ███▄▄ ██▄█▀  ██   
    ██▀██ ▄▄██▀ ██     ██   

    >_ aernyOS • Solus Package tool
    >_ version 0.8


    Commands & Usage:

    aspt init <package-directory>       |  Updates the package directory and creates a new config if necessary
                                           Does not overwrite existing configs

    aspt check                          |  Checks your tracked packages across your defined package directory
    aspt check outdated                 |  Same as <check>, but filtered for outdated only
                                           

    aspt check /path/to/check           |  Checks all packages in a given path
    aspt check outdated /path/to/check  |  Same as <check /path/to/check>, but filtered for outdated only
                                           

    aspt check all                      |  Checks all packages in your defined <package-directory>
    aspt check all outdated             |  Same as <all>, but filtered for outdated only
                                           
    aspt pkg add <pkg-xyz1,xyz2,...>    |  Adds one or more packages to the tracked list
    aspt pkg del <pkgxyz3,name4,...>    |  Deletes one or more packages from the tracked list

    aspt help                           |  Show this help text

```

## Early v0.8 Demo

![aspt demo](demo.gif)
