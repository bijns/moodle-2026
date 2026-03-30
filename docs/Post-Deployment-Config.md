# Post-Deployment Configuration Guide

After a successful deployment, follow these steps to configure your Moodle site with a custom domain, SSL certificate, Microsoft 365 SSO, Viva Learning integration, and recommended settings.

## Prerequisites

- A successful Moodle deployment (see [Deploy.md](./Deploy.md))
- SSH access to the controller VM
- A custom domain name with DNS access
- (Optional) Microsoft 365 admin access for SSO and Viva Learning

## 1. Custom Domain and SSL Certificate

### Point your domain to the load balancer

At your DNS provider, add a CNAME record:

```
lms.yourdomain.com  CNAME  lb-<prefix>.<region>.cloudapp.azure.com
```

You can find the load balancer DNS in the deployment outputs.

### Install a Let's Encrypt certificate

SSH into the controller VM and install certbot:

```bash
sudo apt-get update && sudo apt-get install -y certbot
```

Use DNS validation (recommended, as HTTP validation does not work through the load balancer):

```bash
sudo certbot certonly --manual --preferred-challenges dns -d lms.yourdomain.com
```

Certbot will ask you to create a TXT record:

```
_acme-challenge.lms.yourdomain.com  TXT  <challenge-value>
```

Add that record at your DNS provider, verify with:

```bash
nslookup -type=TXT _acme-challenge.lms.yourdomain.com
```

Once the record resolves, press Enter in certbot to continue.

### Copy certificate files

```bash
sudo cp /etc/letsencrypt/live/lms.yourdomain.com/fullchain.pem /moodle/certs/nginx.crt
sudo cp /etc/letsencrypt/live/lms.yourdomain.com/privkey.pem /moodle/certs/nginx.key
```

Verify the certificate:

```bash
openssl x509 -in /moodle/certs/nginx.crt -noout -subject -dates
```

### Update Moodle configuration

```bash
sudo sed -i "s|\$CFG->wwwroot.*|\$CFG->wwwroot = 'https://lms.yourdomain.com';|" /moodle/html/moodle/config.php
```

Ensure `sslproxy` is set correctly (must be a boolean, not a string):

```bash
grep sslproxy /moodle/html/moodle/config.php
```

If missing or incorrect, add/fix it:

```bash
sudo sed -i "/wwwroot/a \$CFG->sslproxy = true;" /moodle/html/moodle/config.php
```

### Apply changes to VMSS instances

Reimage the VMSS instances to pick up the new certificate:

1. Azure portal -> your resource group -> Virtual Machine Scale Set
2. Click **Instances**
3. Select all instances -> click **Reimage**
4. Wait until all instances show **Running** status

### Fix nginx server name on VMSS (if siteURL was not set at deploy time)

If you did not set the `siteURL` parameter during deployment, the VMSS nginx config will redirect to the load balancer hostname instead of your custom domain. To fix this, use the Azure portal VMSS **Run command** on each instance:

```bash
sed -i 's/lb-<prefix>.<region>.cloudapp.azure.com/lms.yourdomain.com/g' /etc/nginx/sites-enabled/*.conf
mv /etc/nginx/sites-enabled/lb-*.conf /etc/nginx/sites-enabled/lms.yourdomain.com.conf 2>/dev/null
nginx -t && systemctl reload nginx
```

To avoid this issue, set the `siteURL` parameter to your custom domain when deploying.

## 2. Microsoft 365 SSO (OpenID Connect)

### Prerequisites

- The `installO365pluginsSwitch` parameter must be set to `true` during deployment (this is the default in the minimal template). If it was not, see the manual plugin installation section below.

### Register an app in Microsoft Entra ID

1. Go to [Azure Portal -> Microsoft Entra ID -> App registrations](https://portal.azure.com/#blade/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/RegisteredApps)
2. Click **New registration**
3. Set:
   - **Name:** Moodle SSO
   - **Supported account types:** Accounts in this organizational directory only
   - **Redirect URI:** Web -> `https://lms.yourdomain.com/auth/oidc/`
4. After creating, note the **Application (client) ID** and **Directory (tenant) ID**
5. Go to **Certificates & secrets** -> **New client secret** -> copy the secret value
6. Go to **API permissions** -> Add:
   - Microsoft Graph -> Delegated: `openid`, `profile`, `email`, `User.Read`
   - Click **Grant admin consent**

### Configure the OIDC plugin in Moodle

1. **Site administration** -> **Plugins** -> **Authentication** -> **OpenID Connect**
2. Set:
   - **Identity Provider:** Microsoft Entra ID
   - **Client ID:** (from the app registration)
   - **Client Secret:** (from the app registration)
   - **Tenant ID:** (from the app registration)
3. Save

### Enable the auth plugin

1. **Site administration** -> **Plugins** -> **Authentication** -> **Manage authentication**
2. Enable **OpenID Connect** (click the eye icon)
3. Optionally drag it to the top to make it the default login method

Users will now see a Microsoft 365 login button on the Moodle login page.

### Manual O365 plugin installation (if not installed during deployment)

SSH into the controller VM:

```bash
sudo -s
cd /moodle/html/moodle
git clone https://github.com/Microsoft/moodle-auth_oidc.git auth/oidc
git clone https://github.com/Microsoft/moodle-local_o365.git local/o365
git clone https://github.com/Microsoft/moodle-repository_office365.git repository/office365
chown -R www-data:www-data auth/oidc local/o365 repository/office365
```

Then go to **Site administration** -> **Notifications** in your browser to trigger the plugin installation.

## 3. Microsoft Viva Learning Integration

### Enable Moodle Web Services

1. **Site administration** -> **Server** -> **Web services** -> **Overview**
2. **Enable web services** -> toggle On
3. **Enable protocols** -> enable **REST protocol**

### Create a Web Service

1. **Site administration** -> **Server** -> **Web services** -> **External services**
2. Click **Add**
3. Name: `Viva Learning`, check **Enabled**, click **Add service**
4. Click **Add functions** and add:
   - `core_course_get_courses`
   - `core_course_get_categories`
   - `core_course_get_contents`
   - `core_enrol_get_enrolled_users`

### Create a service token

1. **Site administration** -> **Server** -> **Web services** -> **Manage tokens**
2. Click **Create token**
3. Select **Admin** user, select the **Viva Learning** service
4. Click **Save changes** and copy the token

### Configure in Microsoft 365 Admin Center

1. Go to [admin.microsoft.com](https://admin.microsoft.com)
2. **Settings** -> **Org settings** -> **Viva Learning**
3. Click **Add provider** -> select **Moodle**
4. Enter:
   - **Display name:** Moodle LMS
   - **Moodle host URL:** `https://lms.yourdomain.com`
   - **Web service token:** (paste the token)
5. Click **Save**

Sync can take up to 24 hours. After that, your Moodle courses will appear in Viva Learning in Teams. Make sure courses are set to visible and have self-enrolment enabled.

## 4. Recommended Moodle Settings

### Set default language

1. **Site administration** -> **Language** -> **Language packs** -> install your language
2. **Site administration** -> **Language** -> **Language settings** -> set **Default language**

### Set default timezone

1. **Site administration** -> **Location** -> **Location settings**
2. Set **Default timezone** (e.g. `Europe/Amsterdam`)
3. Optionally set **Force default timezone** to the same value

### Disable guest access

1. **Site administration** -> **Plugins** -> **Authentication** -> **Manage authentication**
2. Disable **Guest login button** (click the eye icon)
3. Per course: **Participants** -> **Enrolment methods** -> disable **Guest access**

### Enable self-enrolment

Per course:

1. Go to course -> **Participants** tab
2. **Enrolment methods** (gear icon)
3. Enable **Self enrolment (Student)** (click the eye icon)

### Disable mobile app access

1. **Site administration** -> **Mobile app** -> **Mobile settings**
2. Set **Enable web services for mobile devices** to **No**

### Disable blogs

1. **Site administration** -> **Advanced features**
2. Uncheck **Enable blogs**

### Disable learning plans

1. **Site administration** -> **Advanced features**
2. Uncheck **Enable learning plans**

### Disable forums (prevent new forums)

1. **Site administration** -> **Plugins** -> **Activity modules** -> **Manage activities**
2. Disable **Forum** (click the eye icon)

### Hide participants list from students

1. **Site administration** -> **Users** -> **Permissions** -> **Define roles**
2. Click **Student** -> **Edit**
3. Search for `moodle/course:viewparticipants`
4. Set to **Not set** or **Prevent**

### Assign admin roles

1. **Site administration** -> **Users** -> **Assign system roles**
2. Click **Manager** (or **Site administrator** for full access)
3. Search for the user, select, and click **Add**

### Disable manual login (after SSO is confirmed working)

1. **Site administration** -> **Plugins** -> **Authentication** -> **Manage authentication**
2. Disable **Manual accounts** (click the eye icon)

**Important:** You can always bypass OIDC and access the manual login form at:

```
https://lms.yourdomain.com/login/index.php?nooidc=1
```

## 5. Uploading SCORM Content

1. Go to your course -> turn on **Edit mode** (top right)
2. Click **+ Add an activity or resource** at the bottom of a section
3. Select **SCORM package**
4. Upload your `.zip` file directly (do not extract it)
5. Click **Save and return to course**

## Next Steps

- [Managing your Moodle cluster](./Manage.md)
- [SSL Certificate Management](./SslCert.md)
- [Retrieve deployment details](./Get-Install-Data.md)
