<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=!messagesPerField.existsError('username','password') displayInfo=realm.password && realm.registrationAllowed && !registrationDisabled??; section>
    <#if section = "header">
        <#if messagesPerField.existsError('username','password')>
            <span class="kc-feedback-text kc-feedback-text-error" aria-live="polite">
                ${kcSanitize(messagesPerField.getFirstError('username','password'))?no_esc}
            </span>
        </#if>
    <#elseif section = "form">
        <div id="kc-form" class="sebi-card">
            <div class="sebi-logo-wrap">
                <img class="sebi-logo" src="${url.resourcesPath}/img/sebi-logo.png" alt="SEBI"/>
            </div>
            <h1 id="kc-page-title" class="sebi-title">SEBI Login</h1>
            <p class="sebi-subtitle">Sign in to your account to continue</p>

            <div id="kc-form-wrapper">
                <form id="kc-form-login" onsubmit="login.disabled = true; return true;" action="${url.loginAction}" method="post">
                    <div class="sebi-field">
                        <label for="username" class="sebi-label">${msg("username")}</label>
                        <#if usernameEditDisabled??>
                            <input tabindex="1" id="username" name="username" class="sebi-input" value="${(login.username!'')}" type="text" disabled placeholder="${msg('username')}" aria-invalid="<#if messagesPerField.existsError('username')>true</#if>"/>
                        <#else>
                            <input tabindex="1" id="username" name="username" class="sebi-input" value="${(login.username!'')}" type="text" autofocus autocomplete="username" placeholder="${msg('username')}" aria-invalid="<#if messagesPerField.existsError('username')>true</#if>"/>
                        </#if>
                    </div>

                    <div class="sebi-field">
                        <label for="password" class="sebi-label">${msg("password")}</label>
                        <input tabindex="2" id="password" name="password" class="sebi-input" type="password" autocomplete="current-password" placeholder="${msg('password')}" aria-invalid="<#if messagesPerField.existsError('password')>true</#if>"/>
                    </div>

                    <div class="sebi-actions">
                        <#if realm.resetPasswordAllowed>
                            <span><a tabindex="5" href="${url.loginResetCredentialsUrl}">${msg("doForgotPassword")}</a></span>
                        </#if>
                        <input tabindex="4" name="login" id="kc-login" type="submit" class="sebi-button" value="${msg('doLogIn')}"/>
                    </div>
                </form>
            </div>
        </div>
    </#if>
</@layout.registrationLayout>
