module simpleSales.core

delete {agentlang.ai/LLM {name? "default"}}

{agentlang.ai/LLM {
    name "default",
    service "openai"}
}

entity Lead {
    id UUID @id @default(uuid()),
    firstName String,
    lastName String,
    email Email,
    phone String @optional,
    company String @optional,
    jobTitle String @optional,
    leadStatus String @optional,  // HubSpot hs_lead_status: "NEW", "OPEN", "IN_PROGRESS", "OPEN_DEAL", "UNQUALIFIED", "ATTEMPTED_TO_CONTACT", "CONNECTED", "BAD_TIMING"
    lifecycleStage String @optional,  // HubSpot lifecyclestage: "subscriber", "lead", "marketingqualifiedlead", "salesqualifiedlead", "opportunity", "customer", "evangelist"
    source String @optional,
    notes String @optional,
    hubspotId String @optional,
    score Int @default(0),
    createdAt DateTime @default(now()),
    lastContactedAt DateTime @optional,
    @after {create syncLeadToHubSpot @async}
}

entity Deal {
    id UUID @id @default(uuid()),
    dealName String,
    dealStage String @optional,  // HubSpot dealstage: "appointmentscheduled", "qualifiedtobuy", "presentationscheduled", "decisionmakerboughtin", "contractsent", "closedwon", "closedlost"
    amount String @optional,
    closeDate DateTime @optional,
    priority String @optional,  // "LOW", "MEDIUM", "HIGH" (if using standard priority field)
    hubspotId String @optional,
    leadId UUID @optional,
    createdAt DateTime @default(now()),
    @after {create syncDealToHubSpot @async}
}

entity LeadScore {
    contactId String @id,
    email String,
    score Int @default(0),
    factors Map @optional,
    lastScored DateTime,
    @meta {"documentation": "Tracks lead quality scores"}
}

entity DealTracker {
    dealId String @id,
    dealName String,
    currentStage String,
    previousStage String @optional,
    lastChecked DateTime,
    @meta {"documentation": "Tracks deal stage for change detection"}
}

entity DailySummary {
    id UUID @id @default(uuid()),
    date String,
    newLeadsCount Int @default(0),
    summary String,
    createdAt DateTime @default(now()),
    @meta {"documentation": "Daily lead summary reports"}
}

record LeadSyncResult {
    success Boolean,
    leadsCount Int,
    message String
}

record DealCreationResult {
    success Boolean,
    dealId String @optional,
    hubspotDealId String @optional,
    message String
}

@public agent leadSummaryAgent {
    llm "default",
    role "You are a sales lead analyst.",
    instruction "You create concise summaries of new leads from HubSpot.

    When asked to summarize leads:
    1. Query hubspot/Contact for leads where lifecyclestage='lead' and lead_status='NEW' (UPPERCASE)
    2. Count total leads
    3. Group by job_title (executives, managers, others)
    4. List unique companies
    5. Create a formatted summary with bullet points
    6. Store using simpleSales.core/DailySummary entity

    IMPORTANT: HubSpot hs_lead_status values are UPPERCASE: 'NEW', 'OPEN', 'IN_PROGRESS', 'OPEN_DEAL'
    IMPORTANT: HubSpot lifecyclestage values are lowercase: 'lead', 'marketingqualifiedlead', 'salesqualifiedlead', 'opportunity'

    Be concise and highlight key insights.",
    tools [hubspot/Contact, simpleSales.core/DailySummary]
}

@public agent leadScoringAgent {
    llm "default",
    role "You are a lead scoring specialist.",
    instruction "You score leads based on qualification criteria.

    Scoring rules:
    - C-level titles (CEO, CTO, CFO, Chief, President): 40 points
    - Director or VP titles: 30 points
    - Manager titles: 20 points
    - Has company information: 15 points
    - Corporate email (not gmail/yahoo/hotmail): 15 points

    Process:
    1. Query all contacts where lifecyclestage='lead' (lowercase, no spaces)
    2. For each contact, calculate score based on job_title, company, email
    3. Store score in LeadScore entity (create with contactId from HubSpot contact id)
    4. Find leads with score >= 70
    5. Return list of high-priority leads with names and scores

    IMPORTANT: HubSpot lifecyclestage values are lowercase: 'lead', 'marketingqualifiedlead', 'salesqualifiedlead', 'opportunity'

    Be systematic and thorough.",
    tools [hubspot/Contact, simpleSales.core/LeadScore]
}

@public event enrichContactData {
    contactId String,
    @meta {"documentation": "Uses AI to fill in missing contact information"}
}

@public workflow enrichContactData {
    "Enriching contact data for ID: " + enrichContactData.contactId @as msg;
    console.log(msg);

    {contactEnrichmentAgent {
        message "#js `Analyze contact with ID ${enrichContactData.contactId} from HubSpot. Check for missing information (job_title, company, lifecyclestage). Based on available data (name, email domain), make intelligent suggestions to fill gaps. For example, if email is john.doe@acme.com but company is missing, suggest company='Acme'. If lifecyclestage is missing, set to 'lead' (lowercase). If hs_lead_status is missing, set to 'NEW' (UPPERCASE). Update the contact with enriched data.`"
    }} @as [result];

    "Contact enrichment completed" @as done;
    console.log(done);
    result
}

@public agent contactEnrichmentAgent {
    llm "default",
    role "You are a data enrichment specialist.",
    instruction "You fill in missing contact information intelligently.

    Enrichment logic:
    1. Query the specific contact from HubSpot by id
    2. Check for missing fields: job_title, company, lifecyclestage, lead_status
    3. Analyze available data:
       - Email domain can suggest company name (e.g., john@acme.com → company='Acme')
       - Name patterns can suggest job level
       - Missing lifecyclestage defaults to 'lead' (lowercase)
       - Missing lead_status defaults to 'NEW' (UPPERCASE)
    4. Make intelligent suggestions:
       - If company missing: extract from email domain (remove .com, capitalize)
       - If job_title missing: suggest 'Contact' as default
       - If lifecyclestage missing: set to 'lead' (lowercase, no spaces)
       - If lead_status missing: set to 'NEW' (UPPERCASE)
    5. Update contact in HubSpot with enriched data
    6. Return summary of changes made

    IMPORTANT: Use correct HubSpot API values:
    - hs_lead_status: UPPERCASE ('NEW', 'OPEN', 'IN_PROGRESS', 'OPEN_DEAL', 'UNQUALIFIED', 'ATTEMPTED_TO_CONTACT', 'CONNECTED')
    - lifecyclestage: lowercase ('lead', 'marketingqualifiedlead', 'salesqualifiedlead', 'opportunity', 'customer')

    Be conservative - only fill in high-confidence data.",
    tools [hubspot/Contact]
}

@public agent dealProgressAgent {
    llm "default",
    role "You are a deal pipeline monitor.",
    instruction "You track deal progress and detect stage changes.

    Process:
    1. Query all deals from HubSpot
    2. For each deal:
       a. Look up corresponding DealTracker entity by dealId (use HubSpot deal id)
       b. If DealTracker exists, compare current dealstage with tracker's currentStage
       c. If different, stage has changed - note previous and new stage
       d. If no DealTracker exists, this is a new deal
       e. Create or update DealTracker with current deal info
    3. Provide summary of:
       - Deals that changed stage (with previous → new stage)
       - Deals that reached closedwon (CELEBRATE!)
       - Deals that reached closedlost (note for analysis)
       - New deals discovered

    IMPORTANT: HubSpot dealstage values are lowercase, no spaces:
    - 'appointmentscheduled'
    - 'qualifiedtobuy'
    - 'presentationscheduled'
    - 'decisionmakerboughtin'
    - 'contractsent'
    - 'closedwon'
    - 'closedlost'

    Special handling:
    - closedwon: Note as WIN in summary
    - closedlost: Note as LOST in summary
    - Other changes: Note stage transition

    Be thorough and catch all changes.",
    tools [hubspot/Deal, simpleSales.core/DealTracker]
}

workflow syncLeadToHubSpot {
    "Auto-syncing Lead to HubSpot: " + this.email @as logMessage;
    console.log(logMessage);

    {hubspot/Contact {
        first_name this.firstName,
        last_name this.lastName,
        email this.email,
        job_title this.jobTitle,
        lead_status this.leadStatus,
        lifecycle_stage this.lifecycleStage
    }} @as [hubspotContact];

    "#js `
        const contact = hubspotContact[0];
        contact ? contact.id : null
    `" @as hsId;

    {Lead {
        id? this.id,
        hubspotId hsId
    }} @as [updatedLead];

    "Lead synced to HubSpot with ID: " + hsId @as successMessage;
    console.log(successMessage);

    updatedLead
}

workflow syncDealToHubSpot {
    "Auto-syncing Deal to HubSpot: " + this.dealName @as logMessage;
    console.log(logMessage);

    "#js `
        this.amount ? this.amount.toString() : '0'
    `" @as amountStr;

    "#js `
        this.closeDate ? this.closeDate.toISOString().split('T')[0] : null
    `" @as closeDateStr;

    {hubspot/Deal {
        deal_name this.dealName,
        deal_stage this.dealStage,
        amount amountStr,
        close_date closeDateStr,
        priority this.priority
    }} @as [hubspotDeal];

    "#js `
        const deal = hubspotDeal[0];
        deal ? deal.id : null
    `" @as hsId;

    {Deal {
        id? this.id,
        hubspotId hsId
    }} @as [updatedDeal];

    "Deal synced to HubSpot with ID: " + hsId @as successMessage;
    console.log(successMessage);

    updatedDeal
}

@public workflow createSampleContact {
    "Creating sample contact with CORRECT HubSpot API values" @as msg;
    console.log(msg);

    {hubspot/Contact {
        first_name "Jane",
        last_name "Smith",
        email "jane.smith@techcorp.com",
        job_title "VP of Engineering",
        lead_status "NEW",
        lifecycle_stage "lead"
    }} @as [contact];

    "Sample contact created with lead_status=NEW, lifecyclestage=lead" @as done;
    console.log(done);
    contact
}

@public workflow createSampleDeal {
    "Creating sample deal with CORRECT HubSpot API values" @as msg;
    console.log(msg);

    {hubspot/Deal {
        deal_name "Q1 Enterprise Deal - TechCorp",
        deal_stage "presentationscheduled",
        amount "150000",
        priority "HIGH",
        pipeline "default"
    }} @as [deal];

    "Sample deal created with dealstage=presentationscheduled" @as done;
    console.log(done);
    deal
}

@public workflow createSampleTask {
    "Creating sample task with CORRECT HubSpot API values" @as msg;
    console.log(msg);

    "#js `new Date(Date.now() + 86400000).toISOString()`" @as dueDate;

    {hubspot/Task {
        task_type "EMAIL",
        title "Follow up with Jane Smith",
        description "Discuss pricing and implementation timeline",
        priority "HIGH",
        status "NOT_STARTED",
        due_date dueDate
    }} @as [task];

    "Sample task created with task_type=EMAIL, priority=HIGH, status=NOT_STARTED" @as done;
    console.log(done);
    task
}

@public agent salesAssistant {
    llm "default",
    role "You are a comprehensive sales automation assistant for managing HubSpot CRM.",
    instruction "You help with all sales operations:

    **Lead Management:**
    - Use leadSummaryAgent to get daily summaries of new leads
    - Use leadScoringAgent to prioritize leads by qualification score
    - Use enrichContactData to fill missing information for specific contacts

    **Deal Management:**
    - Use dealProgressAgent to monitor deal pipeline and detect stage changes
    - Track wins (closedwon) and losses (closedlost)

    **Testing:**
    - Use createSampleContact, createSampleDeal, createSampleTask to create test data

    **IMPORTANT - HubSpot API Value Formatting:**
    - hs_lead_status: UPPERCASE with underscores ('NEW', 'OPEN', 'IN_PROGRESS', 'OPEN_DEAL', 'UNQUALIFIED', 'ATTEMPTED_TO_CONTACT', 'CONNECTED')
    - lifecyclestage: lowercase no spaces ('lead', 'marketingqualifiedlead', 'salesqualifiedlead', 'opportunity', 'customer')
    - dealstage: lowercase no spaces ('appointmentscheduled', 'presentationscheduled', 'closedwon', 'closedlost')
    - task_type: UPPERCASE ('EMAIL', 'CALL', 'TODO')
    - task status: UPPERCASE with underscore ('NOT_STARTED', 'IN_PROGRESS', 'COMPLETED')
    - priority: UPPERCASE ('LOW', 'MEDIUM', 'HIGH')

    When asked about leads, always consider scoring and enrichment.
    When asked about deals, track progress and celebrate wins.
    Be proactive in suggesting the right use case for each situation.",

    tools [
        simpleSales.core/leadSummaryAgent,
        simpleSales.core/leadScoringAgent,
        simpleSales.core/enrichContactData,
        simpleSales.core/dealProgressAgent,
        simpleSales.core/createSampleContact,
        simpleSales.core/createSampleDeal,
        simpleSales.core/createSampleTask,
        hubspot/Contact,
        hubspot/Deal,
        hubspot/Task
    ]
}
