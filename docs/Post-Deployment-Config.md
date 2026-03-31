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

Use HTTP validation (the deployment templates configure nginx to serve ACME challenge files before the HTTPS redirect):

```bash
sudo certbot certonly --webroot -w /moodle/html/moodle -d lms.yourdomain.com
```

### Copy certificate files

```bash
sudo cp /etc/letsencrypt/live/lms.yourdomain.com/fullchain.pem /moodle/certs/nginx.crt
sudo cp /etc/letsencrypt/live/lms.yourdomain.com/privkey.pem /moodle/certs/nginx.key
```

Verify the certificate:

```bash
sudo openssl x509 -in /moodle/certs/nginx.crt -noout -subject -dates
```

### Fix sslproxy setting

Ensure `sslproxy` is set to boolean `true`, not the string `'true'`:

```bash
sudo sed -i "s/\$CFG->sslproxy.*/\$CFG->sslproxy = true;/" /moodle/html/moodle/config.php
grep sslproxy /moodle/html/moodle/config.php || sudo sed -i "/wwwroot/a \$CFG->sslproxy = true;" /moodle/html/moodle/config.php
```

### Apply changes to VMSS instances

Reimage the VMSS instances to pick up the new certificate:

1. Azure portal -> your resource group -> Virtual Machine Scale Set
2. Click **Instances**
3. Select all instances -> click **Reimage**
4. Wait until all instances show **Running** status

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

### Articulate Rise export settings

When publishing from Articulate Rise, configure these settings for proper completion tracking:

1. **LMS Format:** SCORM 1.2
2. **Tracking:** Track using quiz result → select your quiz
3. **Reporting:** Passed/Incomplete
4. **Exit Course Link:** On (ensures the SCORM package commits the final status)

Without these settings, the SCORM package will report `browsed` instead of `passed`, and Moodle won't mark the activity as complete.

### Enable activity completion tracking

1. Edit the SCORM activity → **Activity completion**
2. Set **Completion tracking** to **Show activity as complete when conditions are met**
3. Check **Require status** → select **Completed** and/or **Passed**
4. Click **Save**

### Reset a user's SCORM attempt

To reset a user's attempt for retesting:

1. Go to your course → **Grades** tab
2. Find the SCORM activity → click **...** (three dots) next to the user's score
3. Click **Grade analysis**
4. Select the attempt(s) → click **Delete selected attempts**

This clears the user's SCORM data and completion status so they can retake the activity.

## 6. Real-Time Webhook for Course Completion (Power Automate)

To trigger a Power Automate flow in real time when a user completes a SCORM activity, create a custom Moodle event observer plugin.

### Create the plugin

On the controller VM, run:

```bash
sudo mkdir -p /moodle/html/moodle/local/webhooknotify/classes
sudo mkdir -p /moodle/html/moodle/local/webhooknotify/db
```

Create the version file:

```bash
sudo tee /moodle/html/moodle/local/webhooknotify/version.php << 'EOF'
<?php
defined('MOODLE_INTERNAL') || die();
$plugin->component = 'local_webhooknotify';
$plugin->version = 2026032901;
$plugin->requires = 2024042200;
EOF
```

Create the event observer config:

```bash
sudo tee /moodle/html/moodle/local/webhooknotify/db/events.php << 'EOF'
<?php
defined('MOODLE_INTERNAL') || die();
$observers = [
    [
        'eventname' => '\core\event\course_module_completion_updated',
        'callback'  => 'local_webhooknotify_observer::completion_updated',
    ],
];
EOF
```

Create the observer class:

```bash
sudo tee /moodle/html/moodle/local/webhooknotify/classes/observer.php << 'EOF'
<?php
defined('MOODLE_INTERNAL') || die();

class local_webhooknotify_observer {
    public static function completion_updated(\core\event\course_module_completion_updated $event) {
        $data = $event->get_data();
        $url = 'YOUR_POWER_AUTOMATE_HTTP_TRIGGER_URL';

        $payload = json_encode([
            'userid' => $data['relateduserid'],
            'courseid' => $data['courseid'],
            'cmid' => $data['contextinstanceid'],
            'timecreated' => $data['timecreated'],
        ]);

        $ch = curl_init($url);
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, $payload);
        curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, 5);
        curl_exec($ch);
        curl_close($ch);
    }
}
EOF
```

Set permissions:

```bash
sudo chown -R www-data:www-data /moodle/html/moodle/local/webhooknotify
```

### Install the plugin

Go to **Site administration** → **Notifications** and click **Upgrade Moodle database now**.

### Configure the webhook URL

1. Create a Power Automate flow with trigger **"When an HTTP request is received"**
2. Copy the generated URL
3. Update the observer:

```bash
sudo sed -i "s|YOUR_POWER_AUTOMATE_HTTP_TRIGGER_URL|https://prod-XX.westeurope.logic.azure.com/workflows/...|" /moodle/html/moodle/local/webhooknotify/classes/observer.php
```

When a user completes a SCORM activity, Moodle will POST the following JSON to your Power Automate flow:

```json
{
  "userid": 4,
  "courseid": 2,
  "cmid": 2,
  "timecreated": 1774886000
}
```

### Useful REST API endpoints

Get enrolled users (to find user IDs):

```
https://lms.yourdomain.com/webservice/rest/server.php?wstoken=TOKEN&wsfunction=core_enrol_get_enrolled_users&courseid=2&moodlewsrestformat=json
```

Get completion status for a user:

```
https://lms.yourdomain.com/webservice/rest/server.php?wstoken=TOKEN&wsfunction=core_completion_get_activities_completion_status&courseid=2&userid=USER_ID&moodlewsrestformat=json
```

Get SCORM score for a user (custom endpoint):

```
https://lms.yourdomain.com/local/score.php?token=TOKEN&userid=USER_ID&scormid=1
```

## Next Steps

- [Managing your Moodle cluster](./Manage.md)
- [SSL Certificate Management](./SslCert.md)
- [Retrieve deployment details](./Get-Install-Data.md)
