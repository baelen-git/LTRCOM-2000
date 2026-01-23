# Templates and Cloning: Introduction

Each server needs a server profile. Instead of making a lot of the same server profiles, you create a server template and derive this template multiple times.
In a server profile template, vNIC and vHBA templates can be used.

Besides server profile templates, chassis and UCS domain templates are possible. These will not be handled in this lab.

Because the pre-defined Server Profile Template (LAB-RESOURCES) is in the read-only "UCSX-LAB-RESOURCES" org you cannot do any changes to it. 
Therefor we will **clone** this **server profile template**. This has advantages and disadvantages. It is **not** the **best practice** to use clones, but because this is a lab, we want to show you what the limitations are.

One of the limitations is: **Pools cannot be cloned**. They will be created as new pools without any values in them.
Policies, Templates and Server Profiles can be cloned.

First you are going to **clone** a **server profile template** and then **make changes**. 
Once it is a server profile template that you can use, you are going to derive server profiles from this template. 

NOTE:
**Do NOT delete or any server policy or vNIC policy without your -SRVxx at the end, where x is your pod number.**