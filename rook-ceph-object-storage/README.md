## Step-by-Step Flow

```
1. kubectl exec into rook-ceph-tools
        ↓
2. radosgw-admin user create (for each user)
        ↓
3. radosgw-admin user list  ← confirm users exist
        ↓
4. Ceph Dashboard → Object → Buckets → Create
   - Name: test
   - Owner: s3-admin  (now appears in dropdown)
   - Paste policy JSON in Policies field
        ↓
5. Create Bucket
        ↓
6. Verify: radosgw-admin bucket list
           radosgw-admin bucket stats --bucket=test
```


## S3-Admin and Velero-user user creation:

```bash
kubectl -n rook-ceph exec -it rook-ceph-tools-7f5fdcf7fd-sz26n -- bin/bash
bash-5.1$ radosgw-admin user create \
  --uid="s3-admin" \
  --display-name="S3 Admin User" \
  --caps="users=*;buckets=*;metadata=*;usage=*;zone=*"
```
```json
{
    "user_id": "s3-admin",
    "display_name": "S3 Admin User",
    "email": "",
    "suspended": 0,
    "max_buckets": 1000,
    "subusers": [],
    "keys": [
        {
            "user": "s3-admin",
            "access_key": "NOO00WYK152L5GGA987B",
            "secret_key": "ncuvCqOCrZfOUs8oqP7AuSMnQjJqEE9fh9dmpf6E",
            "active": true,
            "create_date": "2026-02-17T09:59:13.360897Z"
        }
    ],
    "swift_keys": [],
    "caps": [
        {
            "type": "buckets",
            "perm": "*"
        },
        {
            "type": "metadata",
            "perm": "*"
        },
        {
            "type": "usage",
            "perm": "*"
        },
        {
            "type": "users",
            "perm": "*"
        },
        {
            "type": "zone",
            "perm": "*"
        }
    ],
    "op_mask": "read, write, delete",
    "default_placement": "",
    "default_storage_class": "",
    "placement_tags": [],
    "bucket_quota": {
        "enabled": false,
        "check_on_raw": false,
        "max_size": -1,
        "max_size_kb": 0,
        "max_objects": -1
    },
    "user_quota": {
        "enabled": false,
        "check_on_raw": false,
        "max_size": -1,
        "max_size_kb": 0,
        "max_objects": -1
    },
    "temp_url_keys": [],
    "type": "rgw",
    "mfa_ids": [],
    "account_id": "",
    "path": "/",
    "create_date": "2026-02-17T09:59:13.352640Z",
    "tags": [],
    "group_ids": []
}
```

```bash
bash-5.1$ radosgw-admin user create \
  --uid="velero-user" \
  --display-name="Velero Backup Service Account"
```

```json
{
    "user_id": "velero-user",
    "display_name": "Velero Backup Service Account",
    "email": "",
    "suspended": 0,
    "max_buckets": 1000,
    "subusers": [],
    "keys": [
        {
            "user": "velero-user",
            "access_key": "AAQJU0PTO82YM6SRP5VW",
            "secret_key": "Xp2xIGFHNggcXB1cenZPQF2Sxj6oySLLaw7KWJA0",
            "active": true,
            "create_date": "2026-02-17T09:59:23.842388Z"
        }
    ],
    "swift_keys": [],
    "caps": [],
    "op_mask": "read, write, delete",
    "default_placement": "",
    "default_storage_class": "",
    "placement_tags": [],
    "bucket_quota": {
        "enabled": false,
        "check_on_raw": false,
        "max_size": -1,
        "max_size_kb": 0,
        "max_objects": -1
    },
    "user_quota": {
        "enabled": false,
        "check_on_raw": false,
        "max_size": -1,
        "max_size_kb": 0,
        "max_objects": -1
    },
    "temp_url_keys": [],
    "type": "rgw",
    "mfa_ids": [],
    "account_id": "",
    "path": "/",
    "create_date": "2026-02-17T09:59:23.840561Z",
    "tags": [],
    "group_ids": []
}
```
```bash
bash-5.1$ radosgw-admin user list
[
    "velero-user",
    "s3-admin"
]
```

### S3 Bucket Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::test",
        "arn:aws:s3:::test/*"
      ],
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    },
    {
      "Sid": "DenyUnauthorizedUsers",
      "Effect": "Deny",
      "NotPrincipal": {
        "AWS": [
          "arn:aws:iam:::user/s3-admin",
          "arn:aws:iam:::user/velero-user"
        ]
      },
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::test",
        "arn:aws:s3:::test/*"
      ]
    },
    {
      "Sid": "AllowAdminFullAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam:::user/s3-admin"
      },
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::test",
        "arn:aws:s3:::test/*"
      ]
    },
    {
      "Sid": "AllowVeleroBackupAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam:::user/velero-user"
      },
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::test",
        "arn:aws:s3:::test/*"
      ]
    }
  ]
}
```