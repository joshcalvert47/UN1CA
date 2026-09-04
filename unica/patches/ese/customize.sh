# SEC_PRODUCT_FEATURE_SECURITY_CONFIG_ESE_CHIP_VENDOR
# SEC_PRODUCT_FEATURE_SECURITY_CONFIG_ESE_COS_NAME
if [[ "$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" == "$TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR" ]] && \
    [[ "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" == "$TARGET_SECURITY_CONFIG_ESE_COS_NAME" ]]; then
    LOG "\033[0;33m! Nothing to do\033[0m"
    return 0
fi

# [
LOG_MISSING_PATCHES()
{
    local MESSAGE="Missing SPF patches for condition ($1: [${!1}], $2: [${!2}])"

    if $DEBUG; then
        LOGW "$MESSAGE"
    else
        ABORT "${MESSAGE}. Aborting"
    fi
}
# ]

DISABLE_ESE_FRAMEWORK()
{
    DECODE_APK "system" "system/framework/framework.jar" || return 1

    local FRAMEWORK_DIR="$APKTOOL_DIR/system/framework/framework.jar"
    local CLASS
    local FILE
    local RELATIVE

    for CLASS in \
        "com/android/server/SemService\$1.smali" \
        "com/android/server/SemService\$SPITimeoutTask.smali" \
        "com/android/server/SemServiceAccessControl\$AllowList.smali" \
        "com/android/server/SemServiceAccessControl\$PackageList.smali" \
        "com/android/server/SemServiceAccessControl.smali" \
        "com/android/server/SemServiceTools.smali"; do
        FILE="$(find "$FRAMEWORK_DIR" -type f -path "*/$CLASS" -print -quit)"
        if [ "$FILE" ]; then
            LOG "- Deleting ${FILE//$APKTOOL_DIR/}"
            rm -f "$FILE" || return 1
        fi
    done

    FILE="$(find "$FRAMEWORK_DIR" -type f -path "*/com/android/server/SemService.smali" -print -quit)"
    if [ "$FILE" ]; then
        LOG "- Replacing ${FILE//$APKTOOL_DIR/}"
        cp -a "$MODPATH/framework.jar/SemService.smali" "$FILE" || return 1
    else
        LOGW "SemService.smali not found in decoded framework"
    fi

    FILE="$(find "$FRAMEWORK_DIR" -type f -path "*/com/samsung/android/ProductPackagesRune.smali" -print -quit)"
    if [ "$FILE" ] && grep -Fq "SEM_DAEMON:Z = true" "$FILE"; then
        RELATIVE="${FILE#$FRAMEWORK_DIR/}"
        SMALI_PATCH "system" "system/framework/framework.jar" "$RELATIVE" "replaceall" \
            "SEM_DAEMON:Z = true" "SEM_DAEMON:Z = false"
    fi

    FILE="$(find "$FRAMEWORK_DIR" -type f -path "*/com/samsung/android/service/SemService/SemServiceManager.smali" -print -quit)"
    if [ "$FILE" ]; then
        RELATIVE="${FILE#$FRAMEWORK_DIR/}"
        if grep -Fq "isSupportSemService:Z = true" "$FILE"; then
            SMALI_PATCH "system" "system/framework/framework.jar" "$RELATIVE" "replaceall" \
                "isSupportSemService:Z = true" "isSupportSemService:Z = false"
        fi
        if grep -Fq "\"$SOURCE_SECURITY_CONFIG_ESE_COS_NAME\"" "$FILE"; then
            SMALI_PATCH "system" "system/framework/framework.jar" "$RELATIVE" "replace" \
                "<clinit>()V" "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" ""
        fi
        if grep -Fq "\"$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR\"" "$FILE"; then
            SMALI_PATCH "system" "system/framework/framework.jar" "$RELATIVE" "replace" \
                "<clinit>()V" "$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" ""
        fi
        if grep -Fq "sput-boolean v0, Lcom/samsung/android/service/SemService/SemServiceManager;->isSupportSemServiceManager:Z" "$FILE" && \
                grep -Fq "const/4 v0, 0x1" "$FILE"; then
            TMP="$FILE.tmp"
            awk '
                {
                    lines[NR] = $0
                    if ($0 ~ /sput-boolean v0, Lcom\/samsung\/android\/service\/SemService\/SemServiceManager;->isSupportSemServiceManager:Z/) {
                        for (i = NR - 1; i > 0; i--) {
                            if (lines[i] !~ /^[[:space:]]*$/) {
                                if (lines[i] ~ /^[[:space:]]*const\/4 v0, 0x1[[:space:]]*$/) {
                                    sub(/0x1/, "0x0", lines[i])
                                }
                                break
                            }
                        }
                    }
                }
                END {
                    for (i = 1; i <= NR; i++) print lines[i]
                }
            ' "$FILE" > "$TMP" && mv "$TMP" "$FILE" || return 1
        fi
    fi
}

DISABLE_ESE_SERVICES()
{
    DECODE_APK "system" "system/framework/services.jar" || return 1

    local SERVICES_DIR="$APKTOOL_DIR/system/framework/services.jar"
    local FILE
    local RELATIVE
    local TMP

    FILE="$(find "$SERVICES_DIR" -type f -path "*/com/android/server/SystemConfig.smali" -print -quit)"
    if [ "$FILE" ]; then
        RELATIVE="${FILE#$SERVICES_DIR/}"
        if grep -Fq "eSE_COS: $SOURCE_SECURITY_CONFIG_ESE_COS_NAME" "$FILE"; then
            SMALI_PATCH "system" "system/framework/services.jar" "$RELATIVE" "replaceall" \
                "eSE_COS: $SOURCE_SECURITY_CONFIG_ESE_COS_NAME" "eSE_COS: "
        fi

        # Newer SystemConfig revisions use different labels/register layouts.
        # Force the eSE feature decision false immediately before it is tested.
        TMP="$FILE.tmp"
        awk '
            /^\.method/ { in_method = 1; found_ese = 0 }
            in_method && /android\.hardware\.se\.omapi\.ese/ { found_ese = 1 }
            in_method && found_ese && /^[[:space:]]*if-(eq|ne)z [vp][0-9]+,/ {
                register = $0
                sub(/^.*if-(eq|ne)z /, "", register)
                sub(/,.*/, "", register)
                print "    const/4 " register ", 0x0"
                found_ese = 0
            }
            { print }
            /^\.end method/ { in_method = 0; found_ese = 0 }
        ' "$FILE" > "$TMP" && mv "$TMP" "$FILE" || return 1
    fi

    FILE="$(find "$SERVICES_DIR" -type f -path "*/com/android/server/SystemServer\$\$ExternalSyntheticLambda10.smali" -print -quit)"
    if [ "$FILE" ] && grep -Fq '"SemService"' "$FILE" && grep -Fq '"Blockchain Service"' "$FILE"; then
        TMP="$FILE.tmp"
        awk '
            /const-string(\/jumbo)? [vp][0-9]+, "SemService"/ { removing = 1; next }
            removing && /const-string(\/jumbo)? [vp][0-9]+, "Blockchain Service"/ { removing = 0; print; next }
            !removing { print }
        ' "$FILE" > "$TMP" && mv "$TMP" "$FILE" || return 1
    fi

    FILE="$(find "$SERVICES_DIR" -type f -path "*/com/samsung/ucm/ucmservice/CredentialManagerService.smali" -print -quit)"
    if [ "$FILE" ]; then
        TMP="$FILE.tmp"
        awk -v vendor="$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" '
            /applet_ese_chip_vendor/ { in_ese = 1; print; next }
            in_ese && /const-string/ {
                if ($0 ~ "\\\"" vendor "\\\"") sub("\\\"" vendor "\\\"", "\\\"\\\"")
                in_ese = 0
            }
            /^\.end method/ { in_ese = 0 }
            { print }
        ' "$FILE" > "$TMP" && mv "$TMP" "$FILE" || return 1
    fi
}

if [[ "$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" == "NXP" ]] && [[ "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" == "JCOP6.2U" ]] && \
        [[ "$TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR" == "none" ]] && [[ "$TARGET_SECURITY_CONFIG_ESE_COS_NAME" == "none" ]]; then
    # Force both eSE capability checks off without depending on the APK's exact smali layout.
    SMALI_PATCH "system" "system/app/SecureElement/SecureElement.apk" \
        "smali/com/android/se/internal/UtilExtension.smali" "return" \
        "supportEse(Landroid/content/Context;)Z" "false"
    SMALI_PATCH "system" "system/app/SecureElement/SecureElement.apk" \
        "smali/com/android/se/internal/UtilExtension.smali" "return" \
        "supportEseHal()Z" "false"
    DELETE_FROM_WORK_DIR "system" "system/bin/sem_daemon"
    DELETE_FROM_WORK_DIR "system" "system/etc/init/sem.rc" 2>&1 | sed "/File not found/d"
    DELETE_FROM_WORK_DIR "system" "system/etc/init/sem_early.rc" 2>&1 | sed "/File not found/d"
    DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.ese.xml"
    DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.sem.factoryapp.xml"

    # The framework layout differs between One UI releases. Apply the same changes
    # as the legacy patch, but only to classes that exist in the decoded framework.
    DISABLE_ESE_FRAMEWORK
    DISABLE_ESE_SERVICES
    ADD_TO_WORK_DIR "$([[ "$TARGET_OS_SINGLE_SYSTEM_IMAGE" == "qssi" ]] && echo "a73xqxx" || echo "a54xnsxx")" \
        "system" "system/lib/libsec_semRil.so" 0 0 644 "u:object_r:system_lib_file:s0"
    ADD_TO_WORK_DIR "$([[ "$TARGET_OS_SINGLE_SYSTEM_IMAGE" == "qssi" ]] && echo "a73xqxx" || echo "a54xnsxx")" \
        "system" "system/lib/libtlc_blockchain_keystore.so" 0 0 644 "u:object_r:system_lib_file:s0"
    ADD_TO_WORK_DIR "$([[ "$TARGET_OS_SINGLE_SYSTEM_IMAGE" == "qssi" ]] && echo "a73xqxx" || echo "a54xnsxx")" \
        "system" "system/lib/libtlc_payment_spay.so" 0 0 644 "u:object_r:system_lib_file:s0"
    ADD_TO_WORK_DIR "$([[ "$TARGET_OS_SINGLE_SYSTEM_IMAGE" == "qssi" ]] && echo "a73xqxx" || echo "a54xnsxx")" \
        "system" "system/lib64/libsec_semRil.so" 0 0 644 "u:object_r:system_lib_file:s0"
    ADD_TO_WORK_DIR "$([[ "$TARGET_OS_SINGLE_SYSTEM_IMAGE" == "qssi" ]] && echo "a73xqxx" || echo "a54xnsxx")" \
        "system" "system/lib64/libtlc_blockchain_keystore.so" 0 0 644 "u:object_r:system_lib_file:s0"
    ADD_TO_WORK_DIR "$([[ "$TARGET_OS_SINGLE_SYSTEM_IMAGE" == "qssi" ]] && echo "a73xqxx" || echo "a54xnsxx")" \
        "system" "system/lib64/libtlc_payment_spay.so" 0 0 644 "u:object_r:system_lib_file:s0"
    DELETE_FROM_WORK_DIR "system" "system/priv-app/SEMFactoryApp"
    DELETE_FROM_WORK_DIR "system" "system/priv-app/SamsungSeAgent"
elif [[ "$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" != "none" ]] && [[ "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" != "none" ]]; then
    if [[ "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" != "$TARGET_SECURITY_CONFIG_ESE_COS_NAME" ]]; then
        SMALI_PATCH "system" "system/app/SecureElement/SecureElement.apk" \
            "smali/com/android/se/internal/UtilExtension.smali" "replace" \
            "<clinit>()V" \
            "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" \
            "${TARGET_SECURITY_CONFIG_ESE_COS_NAME//none/}"
    fi
    if [[ "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" != "$TARGET_SECURITY_CONFIG_ESE_COS_NAME" ]]; then
        SMALI_PATCH "system" "system/app/SecureElement/SecureElement.apk" \
            "smali/com/android/se/internal/UtilExtension.smali" "replace" \
            "supportEse(Landroid/content/Context;)Z" \
            "eSE_COS: $SOURCE_SECURITY_CONFIG_ESE_COS_NAME" \
            "eSE_COS: ${TARGET_SECURITY_CONFIG_ESE_COS_NAME//none/}"
    fi
    if [[ "$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" != "$TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR" ]]; then
        SMALI_PATCH "system" "system/app/SecureElement/SecureElement.apk" \
            "smali/com/android/se/internal/UtilExtension.smali" "replace" \
            "supportEse(Landroid/content/Context;)Z" \
            "eSE_Vendor: $SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" \
            "eSE_Vendor: ${TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR//none/}"
    fi
    if [[ "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" != "$TARGET_SECURITY_CONFIG_ESE_COS_NAME" ]]; then
        SMALI_PATCH "system" "system/app/SecureElement/SecureElement.apk" \
            "smali/com/android/se/internal/UtilExtension.smali" "replace" \
            "supportEseHal()Z" \
            "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" \
            "${TARGET_SECURITY_CONFIG_ESE_COS_NAME//none/}"
    fi
    if [[ "$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" != "$TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR" ]]; then
        SMALI_PATCH "system" "system/framework/framework.jar" \
            "smali_classes6/com/android/server/SemService.smali" "replaceall" \
            "$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" \
            "${TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR//none/}"
    fi
    if [[ "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" != "$TARGET_SECURITY_CONFIG_ESE_COS_NAME" ]]; then
        SMALI_PATCH "system" "system/framework/framework.jar" \
            "smali_classes6/com/android/server/SemService.smali" "replaceall" \
            "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" \
            "${TARGET_SECURITY_CONFIG_ESE_COS_NAME//none/}"
    fi
    if [[ "$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" != "$TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR" ]]; then
        SMALI_PATCH "system" "system/framework/framework.jar" \
            "smali_classes6/com/samsung/android/service/SemService/SemServiceManager.smali" "replaceall" \
            "$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" \
            "${TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR//none/}"
    fi
    if [[ "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" != "$TARGET_SECURITY_CONFIG_ESE_COS_NAME" ]]; then
        SMALI_PATCH "system" "system/framework/framework.jar" \
            "smali_classes6/com/samsung/android/service/SemService/SemServiceManager.smali" "replaceall" \
            "$SOURCE_SECURITY_CONFIG_ESE_COS_NAME" \
            "${TARGET_SECURITY_CONFIG_ESE_COS_NAME//none/}"
    fi
    if [[ "$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" != "$TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR" ]]; then
        SMALI_PATCH "system" "system/framework/services.jar" \
            "smali_classes2/com/samsung/ucm/ucmservice/CredentialManagerService.smali" "replaceall" \
            "$SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" \
            "${TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR//none/}"
    fi
else
    LOG_MISSING_PATCHES "SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR" "TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR" || true
    LOG_MISSING_PATCHES "SOURCE_SECURITY_CONFIG_ESE_COS_NAME" "TARGET_SECURITY_CONFIG_ESE_COS_NAME"
fi

unset -f LOG_MISSING_PATCHES
