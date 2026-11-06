/**********************************************************************************
* Name         : DataImportTestUser
* Author       : Dalton Wilt
* Desc         : The user Data Import tests run as: the running user's profile plus
*                the Data_Import_User permission set.
*
*                Database operations run in user mode, so the running user needs
*                field access to Data_Import_Job__c and Data_Import_Chunk__c. A
*                deploy grants that to no profile, and the deploying admin has none
*                until the permission set is assigned. Running as this user tests
*                the permission set that real importers are given, instead of
*                whatever the org's profiles happen to allow.
* Created On   : 2026-11-06
*
* Used by      : DataImportBatchTest, DataImportJobTest, DataImportWalkerTest
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-11-06    Initial implementation.
**********************************************************************************/

@isTest
public class DataImportTestUser {

    private static User importer;

    /** The importer, created on first use in each test. */
    public static User get() {
        if (importer == null) {
            importer = new User(
                ProfileId = UserInfo.getProfileId(),
                LastName = 'Importer',
                Email = 'importer@example.com',
                Username = 'importer' + System.currentTimeMillis() + '@example.com',
                Alias = 'imprt',
                TimeZoneSidKey = 'America/New_York',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US'
            );
            insert importer;
            insert new PermissionSetAssignment(
                AssigneeId = importer.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Data_Import_User'].Id
            );
        }
        return importer;
    }
}
