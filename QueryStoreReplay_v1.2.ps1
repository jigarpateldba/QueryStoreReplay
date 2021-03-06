    <#  
    .SYNOPSIS
       Exports execution plans and query statements from a Query Store enabled database
       and can replay them on another database.

    .DESCRIPTION
       This script will extract query statements, parameters and parameter values from a
       Query Store enabled database and builds dynamic queries that are stored as .sql 
       files in the ReplayQueries folder to be replayed against a different database.

       Build and maintained by Enrico van de Laar (@evdlaar).

    .LINK
        http://www.querystoretools.com

    .NOTES
        Author  : Enrico van de Laar (Twitter: @evdlaar)
        Date    : January 2017
        Version : 1.2.2

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
        INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A 
        PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT 
        HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF 
        CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE 
        OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

    .PARAMETER SourceServer
        The name of the server where you want to extract query statements from.
        This server must have at least SQL Serer 2016.

    .PARAMETER SourceDatabase
        The name of the source database where you want to extract query statements from.
        The Query Store features must be enabled for this database.

    .PARAMETER TimeWindow
        The amount of time, in hours, that we go back from now to grab queries from the
        source database. For instance, a '2' indicated that we grab all the queries 
        executed in the last 2 hours from now.

    .PARAMETER TargetServer
        The name of the server were the query statements will be replayed against.

    .PARAMETER TargetDatabase
        The name of the database were the query statements will be replayed against.

    .PARAMETER FileLocation
        The location where the logging and export/import folders should be created.
        If not supplied, My Documents will be used.

    .PARAMETER ExportOnly
        When set to $true the query statement replay step will be skipped and only
        the export of execution plans and query statements will be executed.

    .PARAMETER SelectOnly
        When set to $false not only SELECT queries will be replayed on the TargetDatabase.

    .PARAMETER PlanConsistency
        When set to $true an extra check will be executed to check if the generated
        execution plan on the TargetServer is identical to the one on the SourceServer.
        This parameter requires the Query Store to be enabled on the TargetDatabase.

    .PARAMETER ComparePerf
        When set to $true the Query Store Replay script will measure the last query duration
        (in microseconds) on both the source and the target database
        This parameter requires the Query Store to be enabled on the TargetDatabase.

    .PARAMETER IncludeStatements
        When set to $true query statements will be included in the exported .csv file
        generated by the ComparePerf parameter.


    .EXAMPLE
        .\Query_Store_Replay.ps1 -SourceServer localhost -SourceDatabase DatabaseA -TimeWindow 4 -TargetServer localhost -TargetDatabase DatabaseB 
        Exports all queries captured by the Query Store in the last 4 hours from DatabaseA and replays them against DatabaseB.

    .EXAMPLE
        .\Query_Store_Replay.ps1 -SourceServer localhost -SourceDatabase DatabaseA -TimeWindow 2 -ExportOnly $true
        Exports all queries captured by the Query Store in the last 2 hours from DatabaseA, skips replaying the queries.

    .EXAMPLE
        .\Query_Store_Replay.ps1 -SourceServer localhost -SourceDatabase DatabaseA -TimeWindow 4 -TargetServer localhost -TargetDatabase DatabaseB -PlanConsistency $true
        Exports all queries captured by the Query Store on DatabaseA in the last 4 hours and replays them against DatabaseB.
        Every query executed will trigger an additional check to detect of the query generated the same execution plan on the TargetServer as it did on the SourceServer.

    #>

    param
        (
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$SourceServer,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$SourceDatabase,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$TimeWindow,
        [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()][string]$TargetServer,
        [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()][string]$TargetDatabase,
        [Parameter(Mandatory=$false)][string]$FileLocation,
        [Parameter(Mandatory=$false)][boolean]$ExportOnly = $false,
        [Parameter(Mandatory=$false)][boolean]$SelectOnly = $true,
        [Parameter(Mandatory=$false)][boolean]$PlanConsistency = $false,
        [Parameter(Mandatory=$false)][boolean]$ComparePerf = $false,
        [Parameter(Mandatory=$false)][boolean]$IncludeStatements = $false
        )

    Begin 
    
        {

        # Load SMO
        [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null

        # Build timestamp
        $timestamp = Get-Date -Format yyyyMMddHHmmss

        # Check if the $filelocations parameter is empty
        # If it is, we will use the default of My Documents to store plans and logging
        If ([string]::IsNullOrEmpty($FileLocation))
            {

            $rootpath = [Environment]::GetFolderPath("mydocuments")

            }

        Else

            {

            $rootpath = $FileLocation

            }

        # Create the log file
        # The log is created in the users documents
        $logfile = $rootpath + "\QueryStoreReplay_Log_" + $timestamp + ".log"
        New-Item -Path $logfile -ItemType file | out-null

        # Write startup to the log
        $logStartup = $timestamp + " | " + "Query Store Replay script started"
        Add-Content $logfile $logStartup

        # Set our connection to the source SQL Server
        $sqlSourceConn = New-Object Microsoft.SqlServer.Management.Smo.Server $SourceServer

        # Try setting up a connection to the SourceServer
        Try
            {

            $sqlSourceConn.ConnectionContext.Connect()

            }
        
        # If an error occurs, return it to the console and end execution
        Catch
            {
            
            $err = $_.Exception
            write-output $err.Message

            $logSourceConnError = $timestamp + " | " + $err.Message
            Add-Content $logfile $logSourceConnError
            
            while($err.InnerException) 
               {
                    $err = $err.InnerException
                    write-output $err.Message
               }

            break

            }
        
        # If the PlanConsistency or ComparePerf parameter is set to true we need to validate the TargetServer connection through SMO
        If ($PlanConsistency -eq $true -or $ComparePerf -eq $true)

            {

            # Set our connection to the target SQL Server
            $sqlTargetConn = New-Object Microsoft.SqlServer.Management.Smo.Server $TargetServer

            # Try setting up a connection to the TargetServer
            Try
                {

                $sqlTargetConn.ConnectionContext.Connect()

                }
        
            # If an error occurs, return it to the console and end execution
            Catch
                {
            
                $err = $_.Exception
                write-output $err.Message

                $logTargetConnError = $timestamp + " | " + $err.Message
                Add-Content $logfile $logTargetConnError
            
                while($err.InnerException) 
                   {
                        $err = $err.InnerException
                        write-output $err.Message
                   }

                break

                }

            }

        # Write parameter values to the log
        $logParameters = $timestamp + " | " + "The following parameters are supplied: SourceServer: " + $SourceServer + ", SourceDatabase: " + $SourceDatabase + ", TimeWindow: " + $TimeWindow + ", TargetServer: " + $TargetServer + ", TargetDatabase: " + $TargetDatabase+ ", FileLocation: " + $FileLocation + ", ExportOnly: " + $ExportOnly + ", SelectOnly: " + $SelectOnly + ", PlanConsistency: " + $PlanConsistency + ", ComparePerf: " + $ComparePerf
        Add-Content $logfile $logParameters

        ## Starting with some check to detect SQL Server version and Query Store state


        # Check SQL Server version on the source server, should be 2016 (13) or higher
        $sqlSourceVersion = $sqlSourceConn.Version


        # Grab the first number
        $sqlSourceVersion = $sqlSourceVersion
        $sqlSourceVersion = $sqlSourceVersion.ToString().Split(".")[0]

        if ($sqlSourceVersion -ilt "13")

            {
            
            Write-Warning "$SourceServer has a SQL Server version lower than 2016 - ending script execution"

            $logServer2016Check = $timestamp + " | " + $SourceServer + " has a SQL Server version lower than 2016, script processing stopped"
            Add-Content $logfile $logServer2016Check

            break

            }

        # Check if the Query Store is enabled on the source database
        $sqlCheckQueryStoreResult = $sqlSourceConn.Databases.Item($SourceDatabase).QueryStoreOptions.ActualState

        # Check if the Query Store is set to Off or if it isn't configured
        if ($sqlCheckQueryStoreResult -eq "Off" -or [string]::IsNullOrEmpty($sqlCheckQueryStoreResult))
            {

            Write-Warning "$SourceDatabase not enabled for query store - ending script execution"

            $logDBNoQS = $timestamp + " | " + "Query Store is disabled for database " + $SourceDatabase + ", script processing stopped"
            Add-Content $logfile $logDBNoQS

            break

            }

        
        # If the PlanConsistency or ComparePerf parameter is set to true we need to check if Query Store is enabled for the Target DB
        If ($PlanConsistency -eq $true -or $ComparePerf -eq $true)

            {

             # Check if the Query Store is enabled on the target database
            $sqlCheckTargetQueryStoreResult = $sqlTargetConn.Databases.Item($TargetDatabase).QueryStoreOptions.ActualState

            # Check if the Query Store is set to Off or if it isn't configured
            if ($sqlCheckTargetQueryStoreResult -eq "Off" -or [string]::IsNullOrEmpty($sqlCheckTargetQueryStoreResult))
                {

                Write-Warning "$TargetDatabase not enabled for query store - ending script execution"

                $logDBNoQS = $timestamp + " | " + "Query Store is disabled for database " + $TargetDatabase + ", script processing stopped"
                Add-Content $logfile $logDBNoQS

                break

                }

            }

        ## Finished running SQL Server version and Query Store checks

        ## Create / check folders for processing

        # Set the file path where we are going to store the extracted execution plans, right now we store exported data inside the MyDocuments folder
        $filePathQSR=$rootpath +"\QueryStoreReplay"
        
        # If QueryStoreReplay folder doesn't exist, create it
            If (!(Test-Path $filePathQSR))
                {
                New-Item -Path $filePathQSR -ItemType "Directory" | out-null
                }

        $filePathExtract=$filePathQSR+"\ExtractedPlans"
           
            # If export folder doesn't exist, create it
            If (!(Test-Path $filePathExtract))
                {
                New-Item -Path $filePathExtract -ItemType "Directory" | out-null
                }

            # Empty the export folder
            Remove-Item $filePathExtract\*.* | Where { !$_.PSIsContainer }

            # Set the file path where we are going to store our replay workload
            $filePathReplay=$filePathQSR+"\ReplayQueries"

            # Create folder if it doesn't exist
            If (!(Test-Path $filePathReplay))
                {
                New-Item -Path $filePathReplay -ItemType "Directory" | out-null
                }

            # Empty the replay folder
            Remove-Item $filePathReplay\*.* | Where { !$_.PSIsContainer }

            ## Done setting up folders

            # Create a datatable to hold query performance metrics if ComparePerf is $true
            if ($ComparePerf -eq $true)
                {

                # Create the DataTable
                $ComparePerfDT = New-Object System.Data.DataTable

                # Define the columns
                $PDT_SourcePlanID = New-Object System.Data.DataColumn �SourcePlanID�,([string])
                $PDT_SourceQueryID = New-Object System.Data.DataColumn �SourceQueryID�,([string])
                $PDT_QueryHash = New-Object System.Data.DataColumn �QueryHash�,([string])
                $PDT_QueryStatement = New-Object System.Data.DataColumn �QueryStatement�,([string])
                $PDT_TargetPlanID = New-Object System.Data.DataColumn �TargetPlanID�,([string])
                $PDT_TargetQueryID = New-Object System.Data.DataColumn �TargetQueryID�,([string])
                $PDT_SourceDB_Duration = New-Object System.Data.DataColumn �SourceDB_Duration�,([string])
                $PDT_TargetDB_Duration = New-Object System.Data.DataColumn �TargetDB_Duration�,([string])

                # Add columns to DataTable
                $ComparePerfDT.Columns.Add($PDT_SourcePlanID)
                $ComparePerfDT.Columns.Add($PDT_SourceQueryID)
                $ComparePerfDT.Columns.Add($PDT_QueryHash)
                $ComparePerfDT.Columns.Add($PDT_QueryStatement)
                $ComparePerfDT.Columns.Add($PDT_TargetPlanID)
                $ComparePerfDT.Columns.Add($PDT_TargetQueryID)
                $ComparePerfDT.Columns.Add($PDT_SourceDB_Duration)
                $ComparePerfDT.Columns.Add($PDT_TargetDB_Duration)

                }

        } 

    Process

        {

            # Start reading from the Query Store

            # Grab Execution Plans in the last n hours from the Query Store
            $sqlQSGrabPlans = "SELECT
                               qp.plan_id AS 'PlanID',
                               qp.query_id AS 'QueryID',
                               query_plan AS 'ExecutionPlan',
                               CONVERT(char,query_plan_hash,2) AS 'PlanHash',
							   CONVERT(char,qsq.query_hash,2) AS 'QueryHash'
                               FROM sys.query_store_plan qp
							   INNER JOIN sys.query_store_query qsq
							   ON qp.query_id = qsq.query_id
                               WHERE CONVERT(datetime, SWITCHOFFSET(CONVERT(datetimeoffset, qp.last_execution_time), DATENAME(TzOffset, SYSDATETIMEOFFSET()))) >= DATEADD(hour, -1, getdate());"
            
            $sqlResult = $sqlSourceConn.Databases.Item($SourceDatabase).ExecuteWithResults($sqlQSGrabPlans).Tables[0]

            # Check if there are any plans extracted
            If($sqlresult.PlanID.Length -gt 0)
                {

                $exportcounter = 0

                # Start the plan export loop
                foreach ($plan in $sqlResult)
                    {

                    # fix the plan hash string length
                    $planHash = $plan.PlanHash.Trim()

                    # fix the query hash string length
                    $queryHash = $plan.QueryHash.Trim()

                    # Set the XML file to hold our execution plan
                    $fileName=$filePathExtract+"\"+$SourceServer+"_"+$SourceDatabase+"_"+$plan.PlanID+"_"+$planHash+"_"+$queryHash+"_"+$timestamp+".sqlplan"

                    # Write the .sqlplan file
                    $plan.Executionplan | Out-File -FilePath $fileName

                    # If $ComparePerf is set to $true we have to grab the last duration of each query and log them in a DataTable
                    If ($ComparePerf -eq $true)
                        {

                        # Run a query to get the last execution duration of the Plan
                        $sqlSourceLastDuration = "SELECT TOP 1 last_duration FROM sys.query_store_runtime_stats WHERE plan_id = "+ $plan.PlanID +" ORDER BY last_execution_time DESC;"
                        $sqlResult = $sqlSourceConn.Databases.Item($SourceDatabase).ExecuteWithResults($sqlSourceLastDuration).Tables[0]

                        $PDR_Row = $ComparePerfDT.NewRow()

                        $PDR_Row.SourcePlanID = $plan.PlanID
                        $PDR_Row.SourceQueryID = $plan.QueryID
                        $PDR_Row.QueryHash = $queryHash
                        $PDR_Row.SourceDB_Duration = $sqlResult.last_Duration

                        $ComparePerfDT.Rows.Add($PDR_Row)

                        }
                    
                    $exportcounter++

                    }

                    # Log the amount of plans that were extracted
                    $logPlanCount = $timestamp + " | " + $exportcounter + " Execution Plans were extracted from the Query Store"
                    Add-Content $logfile $logPlanCount



                }

            Else
        
                # Throw an error if no execution plans are extracted
                {
                    
                Write-Warning "There were no execution plans in the last "+$timestamp+ " hours in the query store"
                
                }

            # Now that we have all the execution plans from our source server
            # extract the query statement and parameters from the execution plan

            # Declare the XML object
            $xml = New-Object 'System.Xml.XmlDocument'

            $planfiles = Get-ChildItem $filePathExtract -filter "*.sqlplan"

            # Set a counter so we know how many parameters we extracted
            $p=0

            # Set a counter so we know how many statements we extracted
            $s=0

            # For each .sqlplan file
            foreach ($planfile in $planfiles)
                {

                # Grab the Query Store PlanID from the .sqlplan file
                $filePlanID = $planfile.ToString().Split("_")[2]

                # Grab the Plan Hash from the .sqlplan file
                $filePlanHash = $planfile.ToString().Split("_")[3]

                # Grab the Query Hash from the .sqlplan file
                $fileQueryHash = $planfile.ToString().Split("_")[4]

                # Fix the path to the .sqlplan file
                $planfile = $filePathExtract + "\" + $planfile

                # Build the file
                $fileNameReplay=$filePathReplay+"\"+$SourceServer+"_"+$SourceDatabase+"_"+$filePlanID+"_"+$filePlanHash+"_"+$fileQueryHash+"_"+$timestamp+".sql"

                New-Item -Path $fileNameReplay -ItemType file | out-null

                # Load the Execution Plan from the .sqlplan files
                $filedata = [string]::Join([Environment]::NewLine,(Get-Content $planfile))
                $xml.LoadXml($filedata);

                #Setup the XmlNamespaceManager
                $xmlNsm = new-object 'System.Xml.XmlNamespaceManager' $xml.NameTable;
                $xmlNsm.AddNamespace("sm", "http://schemas.microsoft.com/sqlserver/2004/07/showplan");

                # Start the XML loop

                # Grab parameters if they are present
                $xml.SelectNodes("//sm:ColumnReference", $xmlNsm) |`
	                where { $_.Column -ne $null -and $_.Column -ne [string]::Empty} | % `
		                    {

			                    $ParentNode = $_.ParentNode.Name;
			                    if($_.ParentNode.Name -eq "ParameterList")
			
                                {
				
                                $QueryParameters = $_.Column
                                $QueryParametersValue = $_.ParameterCompiledValue.trim('()')
                                $QueryParametersType = $_.ParameterDataType

                                $DeclareParameters = "DECLARE "+ $QueryParameters + " " + $QueryParametersType + " = " + $QueryParametersValue

                                Add-Content $fileNameReplay $DeclareParameters

                                $p++
				
			                    }

                            }

                # grab the SQL statement
                $xml.SelectNodes("//sm:StmtSimple", $xmlNsm) |`
	                where {$_.StatementText -ne $null -and $_.StatementText -ne [string]::Empty} | % `
		                    {
			
                            # For each statement perform an action
                            $DeclareStatement = "`r`n" + $_.StatementText

                            # DEBUG: Check query statement length for later use, max size of statement in plan file is 4250/3999 chars
                            $QueryStatementLength = $_.StatementText.Length

                            Add-Content $fileNameReplay $DeclareStatement

                            # Check if SelectOnly is set to true and the statement is not a SELECT statement
                            If ($_.StatementType -ne "SELECT" -and $SelectOnly -eq $true)

                                {

                                # The $SelectOnly parameter is set to $true and the query statement is not a SELECT statement, let's delete the file to avoid replay
                                Remove-Item $fileNameReplay

                                }

                            # Insert the first n characters of the statement into the ComparePerf database table if ComparePerf is $true and IncludeStatements is $true
                            if ($ComparePerf -eq $true -and $IncludeStatements -eq $true)
                                {

                                # Check the length of the statement, only return a maximum of 150 characters
                                if ($QueryStatementLength -le 100)
                                    {
                                    
                                    $QueryStatementComparePerf = $DeclareStatement.Replace("`n",' ')

                                    }
                                else
                                    {
                                    $QueryStatementComparePerf = $DeclareStatement.substring(0, 100)
                                    }


                                ($ComparePerfDT.Rows | Where-Object {($_.SourcePlanID -eq $filePlanID)}).QueryStatement = $QueryStatementComparePerf

                                }

                            $s++
		    
                            }
      
                  # Done plan wrangling
                  }

            # Log amount of statements extracted
            $logStatementCount = $timestamp + " | " + $s + " statement(s) were extracted from Execution Plans"
            Add-Content $logfile $logStatementCount

            # Log amount of parameters extracted
            $logParameterCount = $timestamp + " | " + $p + " parameter(s) were extracted from Execution Plans"
            Add-Content $logfile $logParameterCount

            # Check if ExportOnly is not enabled, if it is we can stop processing, else continue
            If ($ExportOnly -eq $false) 
    
                {
                # No ExportOnly, continue query executions against Target

                # We have to check the connection to the target server and database first
                Try
                    {
                    Invoke-Sqlcmd -ServerInstance $TargetServer -Database $TargetDatabase -Query "SELECT DB_NAME()" -ErrorAction Stop | out-null
                    }

                Catch

                    {
                    $err = $_.Exception
                    write-output $err.Message

                    $logTargetConnError = $timestamp + " | " + $err.Message
                    Add-Content $logfile $logTargetConnError
            
                    while($err.InnerException) 
                       {
                            $err = $err.InnerException
                            write-output $err.Message
                       }

                    break
                    }


                # Set error count variable
                $e = 0

                $queryfiles = Get-ChildItem $filePathReplay -filter "*.sql"

                $logReplay = $timestamp + " | " + "Query Store Replay started with replaying " + $queryfiles.Count + " queries"
                Add-Content $logfile $logReplay

                # If PlanConsistency parameter is set to true log a message indicating we will compare plans
                if ($PlanConsistency -eq $true)

                    {
                
                    $logReplayNCTrue = $timestamp + " | PlanConsistency check set to True, performing plan comparison between source and target" 
                    Add-Content $logfile $logReplayNCTrue

                    }
                
                # Start the replay of the workload
                foreach ($queryfile in $queryfiles)
                    {

                    $sqlErr = $null
            
                    $sqlReplay=Invoke-SqlCmd -MaxCharLength 999999 -Inputfile $queryfile.FullName -ServerInstance $TargetServer -Database $TargetDatabase -ErrorVariable sqlErr -ErrorAction SilentlyContinue | Out-Null

                    if ($sqlErr) 
                        { 
                            $logReplayError = $timestamp + " | ERROR: " + $queryfile.Name + $sqlErr
                            Add-Content $logfile $logReplayError
                    
                            $e++

                        }
                    
                    # Check if the PlanConsistency parameter is set to true
                    # In that case we have to check if the replay file generated the same execution plan on the target as the source
                    if ($PlanConsistency -eq $true)

                        {
                        # Check if generated execution plan is consistent with the plan on the SourceServer

                        $planconsistencycheck = 0
                    
                        # Grab the Plan Hash from the .sqlplan file
                        $fileSourcePlanHash = $queryfile.ToString().Split("_")[3]

                        # Check if the execution plan Hash exists in the target Query Store
                        $sqlQSGrabTargetPlans = "SELECT COUNT(*) AS 'HashNr' FROM sys.query_store_plan WHERE CONVERT(char,query_plan_hash,2) = '" + $fileSourcePlanHash + "';"
            
                        $sqlResult = $sqlTargetConn.Databases.Item($TargetDatabase).ExecuteWithResults($sqlQSGrabTargetPlans).Tables[0]

                        #If a query didn't result in an identical plan being generated on the TargetServer
                        if ($sqlResult.HashNr -eq 0)

                            {
                        
                            $logReplayNCPlan = $timestamp + " | INFO: " + $queryfile.Name + " generated a different execution plan on the TargetServer"
                            Add-Content $logfile $logReplayNCPlan

                            $planconsistencycheck = 1

                            }

                        }

                    # Check if the ComparePerf parameter is set to true, if it is we have to grab the target runtime using the queryhash
                    # and add it to the ComparePerfDT datatable
                    if ($ComparePerf -eq $true)

                        {

                        # We need to sleep for a few miliseconds, if we continue too quickly data will not be present in the target QS yet
                        Start-Sleep -m 100

                        # Grab the query hash from the replay file
                        $fileSourceQueryHash = $queryfile.ToString().Split("_")[4]
                        
                        $sqlTargetLastDuration = "SELECT TOP 1 
		                                           qsp.plan_id,
		                                           qsq.query_id,
		                                           qsrs.last_duration
		                                         FROM sys.query_store_query qsq
		                                         LEFT JOIN sys.query_store_plan qsp
		                                         ON qsq.query_id = qsp.query_id
		                                         LEFT JOIN sys.query_store_runtime_stats qsrs
		                                         ON qsp.plan_id = qsrs.plan_id
		                                         WHERE CONVERT(char,qsq.query_hash,2) = '"+$fileSourceQueryHash+"'
		                                         ORDER BY qsq.last_execution_time DESC"
            
                        $sqlTargetLD = $sqlTargetConn.Databases.Item($TargetDatabase).ExecuteWithResults($sqlTargetLastDuration).Tables[0]

                        If ($sqlTargetLD.last_duration -ne [string]::Empty -or $sqlTargetLD.last_duration -ne '')
                            {

                            $TargetLastDuration = $sqlTargetLD.last_duration.tostring()

                            }

                        # If a different execution plan was generated on the TargetServer provide a visual indicator
                        If ($planconsistencycheck -eq 1)
                            {
                            $TargetLastDuration = $TargetLastDuration + " *"
                            }

                        # Update the datatable with the Target last duration time and Query and Plan ID's
                        Try
                            {

                                ($ComparePerfDT.Rows | Where-Object {($_.QueryHash -eq $fileSourceQueryHash)}) | Foreach {$_.TargetDB_Duration = $TargetLastDuration}
                                ($ComparePerfDT.Rows | Where-Object {($_.QueryHash -eq $fileSourceQueryHash)}) | Foreach {$_.TargetPlanID = $sqlTargetLD.plan_id}
                                ($ComparePerfDT.Rows | Where-Object {($_.QueryHash -eq $fileSourceQueryHash)}) | Foreach {$_.TargetQueryID = $sqlTargetLD.query_id}
                               

                            }

                        Catch

                            {
                                write-warning "$queryfile : could not retrieve query metrics on target server."
                            }

                        }


                    }

                $goodQueries = $queryfiles.Count - $e
        
                $logReplayQueryCount = $timestamp + " | " + "Query Store Replay replayed " + $goodQueries + " queries successfully and " + $e + " queries could not be replayed"
                Add-Content $logfile $logReplayQueryCount

                }

            Else

                {
        
                $logExportSkipped = $timestamp + " | " + "Query Store Replay script skipped replaying queries"
                Add-Content $logfile $logExportSkipped

                }

            $logDBCompleted = $timestamp + " | " + "Query Store Replay script successfully finished!"
            Add-Content $logfile $logDBCompleted

            # End of processing
            }

    End
    {
    
    # Set connection to disconnect
    $sqlSourceConn.ConnectionContext.Disconnect()

     If ($PlanConsistency -eq $true -or $ComparePerf -eq $true)

            { 

            $sqlTargetConn.ConnectionContext.Disconnect()

            }

    ######################################################
    # Return table with the query performance comparison
    ######################################################

    if ($ComparePerf -eq $true)

        {

        $ComparePerfDT | Format-Table -Property SourcePlanID, SourceQueryID, TargetPlanID, TargetQueryID, SourceDB_Duration, TargetDB_Duration, QueryStatement -Wrap -AutoSize 


        }
    
    }
