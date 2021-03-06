#Generate trigger
param ([string] $ServerName = "localhost", [Parameter(Mandatory=$true)][string] $DatabaseName, [string] $TableSchema = "DBO", [Parameter(Mandatory=$true)] [string] $TableName, [Parameter(Mandatory=$true)] [string] $OutputDirectory);
#region References

[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Smo") 			| Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SmoEnum") 		| Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SmoExtended") 	| Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.ConnectionInfo") | Out-Null

#endregion References
cls

$AuditTableName = $TableName;


$Server = New-Object('Microsoft.SqlServer.Management.Smo.Server') $ServerName;
$Database = $Server.Databases[$DatabaseName]
$Table = $Database.Tables[$TableName];

$i=0;
$ColumnListFormat  = $Table.Columns | Foreach {if ($i++ -gt 0){"{0}"+$_.Name;}else{" "+$_.Name}};

$TableCols = $Table.Columns | Foreach {[string]::Format("{0} {1} NULL", $_.Name, $_.DataType, "SIZE");}
$ColumnList = [string]::Format($ColumnListFormat, ",");
$InsertedColumnList = [string]::Format($ColumnListFormat, "`n`t`t`t,");
$DeletedColumnList = [string]::Format($ColumnListFormat, "`n");

	$NewTable = New-Object([Microsoft.SqlServer.Management.Smo.Table])($Database, $AuditTableName, "AUDIT");
	
	
	$NewPKColumn = New-Object([Microsoft.SqlServer.Management.Smo.Column])($NewTable, "AuditRecordID");
	$NewPKColumn.DataType = [Microsoft.SqlServer.Management.Smo.DataType]::BigInt;
	$NewPKColumn.Identity = $true;
	$NewPKColumn.IdentityIncrement = 1;
	$NewPKColumn.IdentitySeed = 1;
	$NewPKColumn.Nullable = $false;
	$NewTable.Columns.Add($NewPKColumn);
	
	
	
	foreach ($Column in $Table.Columns)
	{
			$NewColumn = New-Object([Microsoft.SqlServer.Management.Smo.Column])($NewTable, $Column.Name);
			$NewColumn.DataType = $Column.DataType;
			$NewColumn.Nullable = $true;
			$NewTable.Columns.Add($NewColumn);
	}
	
	$NewPKIndex = New-Object([Microsoft.SqlServer.Management.Smo.Index])($NewTable, [string]::Format("PK_AUDIT_{0}", $AuditTableName));
	$NewPKIndex.IndexKeyType = [Microsoft.SqlServer.Management.Smo.IndexKeyType]::DriPrimaryKey;
	$NewPKIdxColumn = New-Object([Microsoft.SqlServer.Management.Smo.IndexedColumn])($NewPKIndex, "AuditRecordID");
	$NewPKIndex.IndexedColumns.Add($NewPKIdxColumn);
	$NewTable.Indexes.Add($NewPKIndex);
	
	$NewColumn = New-Object([Microsoft.SqlServer.Management.Smo.Column])($NewTable, "AuditRecordDateTime");
	$NewColumn.DataType = [Microsoft.SqlServer.Management.Smo.DataType]::DateTimeOffset(7);
	$NewColumn.Nullable = $false;
	$NewColumn.AddDefaultConstraint([string]::Format("DF_{0}_AuditRecordDateTime", $TableName)).Text = "SYSDATETIMEOFFSET()";
	$NewTable.Columns.Add($NewColumn);
	
	$NewColumn = New-Object([Microsoft.SqlServer.Management.Smo.Column])($NewTable, "AuditGroupGUID");
	$NewColumn.DataType = [Microsoft.SqlServer.Management.Smo.DataType]::UniqueIdentifier;
	$NewColumn.Nullable = $false;
	$NewTable.Columns.Add($NewColumn);
	
	$NewColumn = New-Object([Microsoft.SqlServer.Management.Smo.Column])($NewTable, "InsertUpdateDeleteFlag");
	$DataType = New-Object([Microsoft.SqlServer.Management.Smo.DataType]);
	$DataType.MaximumLength = 1;
	$DataType.SqlDataType = [Microsoft.SqlServer.Management.Smo.SqlDataType]::Char;
	$NewColumn.DataType = $DataType;
	$NewColumn.Nullable = $false;
	$NewTable.Columns.Add($NewColumn);
	
	$NewColumn = New-Object([Microsoft.SqlServer.Management.Smo.Column])($NewTable, "IsBeforeRecord");
	$NewColumn.DataType = [Microsoft.SqlServer.Management.Smo.DataType]::Bit;
	$NewColumn.Nullable = $false;
	$NewTable.Columns.Add($NewColumn);
	
	$Options = New-Object ([Microsoft.SqlServer.Management.Smo.ScriptingOptions]);
	$Options.DriPrimaryKey = $true;
	$Options.DriDefaults = $true;
	$AuditTableSQL = $NewTable.Script($Options);


$AuditColumnsTemplate = @"

CREATE TABLE AUDIT.{0}_Columns(
	 {0}_ColumnsID                   BIGINT IDENTITY(1,1)    NOT NULL
	,AUDITGroupGUID                  UNIQUEIDENTIFIER        NOT NULL
	,ColumnName                      VARCHAR(128)            NOT NULL
     CONSTRAINT PK_AUDIT_{0}_Columns PRIMARY KEY CLUSTERED 
    (
	    {0}_ColumnsID ASC
    )
)

"@;

#0 = TableName
#1 = IUD
#2 = Column list
#3 = Inserted column list
#4 = Deleted column list
#5 = TableSchema
$TriggerTemplate = @"
IF OBJECT_ID('{5}.TR_{0}_AUDIT_{1}') IS NOT NULL DROP TRIGGER {5}.TR_{0}_AUDIT_{1}
GO

CREATE TRIGGER {5}.TR_{0}_AUDIT_{1}
ON $TableSchema.{0}
FOR INSERT, UPDATE, DELETE
AS

	SET NOCOUNT ON
	
		DECLARE @AuditGroupGUID UNIQUEIDENTIFIER
		DECLARE @TableName SYSNAME

		SELECT @AuditGroupGUID = NEWID()
		,@TableName = '{0}'

		DECLARE @CRUDFlag CHAR(1)

		IF EXISTS (SELECT TOP 1 1 FROM INSERTED)
			IF EXISTS (SELECT TOP 1 1 FROM DELETED)
				SET @CRUDFlag = 'U'
			ELSE
				SET @CRUDFlag = 'I'
		ELSE
			    SET @CRUDFlag = 'D'
				
		INSERT INTO AUDIT.{0}
		({2}, AuditRecordDateTime, AuditGroupGUID, InsertUpdateDeleteFlag, IsBeforeRecord)
		SELECT 
			{3}
		    ,AuditRecordDateTime  = GETUTCDATE()
		    ,AuditGroupGUID          = @AuditGroupGUID
		    ,InsertUpdateDeleteFlag  = @CRUDFlag
		    ,IsBeforeRecord = 1
		  FROM DELETED
		
		INSERT INTO AUDIT.{0}
		({2}, AuditRecordDateTime, AuditGroupGUID, InsertUpdateDeleteFlag, IsBeforeRecord)
		SELECT 
			{3}
		    ,AuditRecordDateTime  = GETUTCDATE()
		    ,AuditGroupGUID          = @AuditGroupGUID
		    ,InsertUpdateDeleteFlag  = @CRUDFlag
		    ,IsBeforeRecord = 0
		  FROM INSERTED
	      
		INSERT INTO AUDIT.{0}_Columns
		(AUDITGroupGUID, ColumnName)
		SELECT M.AUDITGroupGUID, M.ColumnName
		FROM
		(
			SELECT 
				AUDITGroupGUID = @AuditGroupGUID
				,ColumnName =  CASE WHEN sys.fn_IsBitSetInBitmask(COLUMNS_UPDATED(), COLUMN_ID) > 0 THEN COLUMN_NAME ELSE NULL END
			FROM (
				SELECT 
					  TABLE_NAME
					, COLUMN_NAME
					, COLUMNPROPERTY(OBJECT_ID(TABLE_SCHEMA + '.' + TABLE_NAME), COLUMN_NAME, 'ColumnID') AS COLUMN_ID
				FROM INFORMATION_SCHEMA.COLUMNS
				WHERE TABLE_NAME = @TableName
			) AS N
		) AS M
		WHERE M.ColumnName IS NOT NULL

		SET NOCOUNT OFF
"@;


$AuditColumnsTableSQL = [string]::Format($AuditColumnsTemplate, $TableName);
$TriggerSQL = [string]::Format($TriggerTemplate, $TableName, "IUD", $ColumnList, $InsertedColumnList, $DeletedColumnList, $TableSchema);


$OutFile = [string]::Format("{0}\{1}_AuditColumns.sql", $OutputDirectory, $TableName);
$AuditColumnsTableSQL | Out-File $OutFile -Force

$OutFile = [string]::Format("{0}\{1}_AuditTable.sql", $OutputDirectory, $TableName);
$AuditTableSQL | Out-File $OutFile -Force

$OutFile = [string]::Format("{0}\{1}_AuditTrigger.sql", $OutputDirectory, $TableName);
$TriggerSQL  | Out-File $OutFile -Force






