###################################################

# Running the full model with whole area and fishing
# Produces plots every five years
# Get spatial plots as well as age based histograms
# See script six for more complex plots
###################################################


library(tidyverse)
library(dplyr)
library(ggplot2)
library(sf)
library(forcats)
library(RColorBrewer)
library(MQMF)
library(Rcpp)
library(RcppArmadillo)
library(raster)
library(gmailr)
library(beepr)

rm(list = ls())

#### Setting Up to Send Email ####
rappdirs::user_data_dir("gmailr")
path_old <- "~/Downloads/client_secret_197921613648-unj6hrruc81rfdj9f6am0uvfvhtq2a3p.apps.googleusercontent.com.json"
d <- fs::dir_create(rappdirs::user_data_dir("gmailr"), recurse=TRUE)
fs::file_move(path_old, d)

gm_auth_configure()

gm_oauth_client()

gm_auth()

#### SET DIRECTORIES ####
working.dir <- dirname(rstudioapi::getActiveDocumentContext()$path) # to directory of current file - or type your own

data_dir <- paste(working.dir, "Data", sep="/")
fig_dir <- paste(working.dir, "Figures", sep="/")
sp_dir <- paste(working.dir, "Spatial_Data", sep="/")
sg_dir <- paste(working.dir, "Staging", sep="/")
pop_dir <-  paste(working.dir, "Output_Population", sep="/")
sim_dir <- paste(working.dir, "Simulations", sep="/")

## Read in functions
setwd(working.dir)
sourceCpp("X_Model_RccpArm.cpp")
source("X_Functions.R")

#### PRE-SETS ####

## Create colours for the plot
pop.groups <- c(0,10,20,30,40,50,60,70,80,90,100,110,120,130,140,150)
my.colours <- "PuBu"

model.name = "ningaloo"
Movement_Speed = "fast_movement"

#### LOAD FILES ####

## Normal Model Files
setwd(sg_dir)
AdultMove <- readRDS(paste0(model.name, sep="_", "movement_fast"))
Settlement <- readRDS(paste0(model.name, sep="_","recruitment"))
# Effort <- readRDS(paste0(model.name, sep="_", "fishing"))
NoTake <- readRDS(paste0(model.name, sep="_","NoTakeList"))
Water <- readRDS(paste0(model.name, sep="_","water")) %>% 
  st_make_valid()
BurnInPop <- readRDS(paste0(model.name, sep="_", "BurnInPop_High_M"))
Selectivity <- readRDS("selret")
Mature <- readRDS("maturity")
Weight <- readRDS("weight")

# Simulation Files
# Need to set different seeds for each scenario so that they are different but run the same every time
setwd(sim_dir)
Effort <- readRDS(paste0(model.name, sep="_", "S03_fishing"))
Scenario <- "S03"

#### SET UP SPATIAL EXTENT FOR PLOTS ####
setwd(sp_dir)
bathy <- raster("ga_bathy_ningaloocrop.tif")
WHA <- st_read("2013_02_WorldHeritageMarineProgramme.shp") %>% 
  st_transform(4283)%>%
  st_make_valid %>% 
  st_crop(xmin=112.5, xmax=114.7, ymin=-24, ymax=-20.5) 

#* Create list of cells to restrict plots to shallow Water (<30m)
Water_points <- st_centroid_within_poly(Water) 

Water_bathy <- raster::extract(bathy, Water_points, fun=mean, df=TRUE)

Water_bathy <- Water_bathy %>% 
  mutate(ID = as.factor(ID))

model_WHA <- Water %>% 
  st_intersects(., WHA) %>% 
  as.data.frame()

Water_WHA <- Water[c(as.numeric(model_WHA$row.id)), ]

Water_shallow <- Water_WHA %>% 
  mutate(ID = as.factor(ID)) %>% 
  left_join(., Water_bathy, by="ID") %>% 
  rename(bathy = "ga_bathy_ningaloocrop") %>% 
  #filter(bathy >= c(-30)) %>% 
  filter(!is.na(bathy))

shallow_cells_NTZ <- Water_shallow %>% 
  filter(Fished_2017 %in% c("N")) %>% 
  st_drop_geometry(.)

shallow_cells_F <- Water_shallow %>% 
  filter(Fished_2017 %in% c("Y")) %>% 
  st_drop_geometry(.)

shallow_NTZ_ID <- as.numeric(levels(shallow_cells_NTZ$ID))[as.integer(shallow_cells_NTZ$ID)]
shallow_F_ID <- as.numeric(levels(shallow_cells_F$ID))[as.integer(shallow_cells_F$ID)]

setwd(sg_dir)

saveRDS(shallow_NTZ_ID, paste0(model.name, sep="_", "NTZ_Cell_ID"))
saveRDS(shallow_F_ID, paste0(model.name, sep="_", "F_Cell_ID"))

#### PARAMETER VALUES ####
## Natural Mortality
# We have instantaneous mortality from Marriott et al 2011 and we need to convert that into monthly mortality
NatMort = 0.146

## Potentially 18% mortality rate per day for larvae https://www.nature.com/articles/s41598-022-25629-w
## Larval duration is thought to be ~45 days https://www.researchgate.net/publication/221894788_Understanding_age-specific_dispersal_in_fishes_through_hydrodynamic_modelling_genetic_simulations_and_microsatellite_DNA_analysis#pf9


# Beverton-Holt Recruitment Values - Have sourced the script but need to check that alpha and beta are there
BHa = 0.4344209 #0.4344209
BHb = 0.0001708755
PF = 0.5

# Model settings
MaxCell = nrow(Water) # Number of cells in the model
MaxAge = 30 # The max age of the fish in the model -1 to account for the fact that Rcpp functions start from 0
MaxYear = 59 # Number of years the model should run for -1 to account for the fact that Rcpp functions start from 0
# PlotTotal <- T #This is whether you want a line plot of the total or the map

Pop.Groups <- seq(1,12)

#### SET UP LISTS TO HOLD THE PLOTS ####
SpatialPlots <- list()
LengthPlots <- list()
AgePlots <- list()
TimesPlotted = 0

#### SET UP INITIAL POPULATION ####

## To save population information
PopTotal <- array(0, dim=c(MaxCell, 12, MaxYear)) # This is our total population, all ages are summed and each column is a month (each layer is a year)
Total <- array(NA, dim=c(MaxYear,1)) # For plotting
Pop.Total.Dist <- array(0, dim=c(MaxCell, MaxYear))

## To save catch information
age.catch <- array(0, dim=c(12, MaxAge, MaxYear))
catch.by.cell <- array(0, dim=c(MaxCell, MaxYear))
catch.by.age <- array(0, dim=(c(MaxAge, MaxYear)))
catch.by.weight <- array(0, dim=(c(MaxCell, MaxYear)))

## Save all information by simulation
Sim.Pop <- array(0, dim=c(MaxYear, 200))
Sim.Ages <- array(0, dim=c(MaxAge, MaxYear, 200))

Sp.Pop.F <- array(0, dim=c(length(shallow_F_ID), MaxAge, MaxYear))
Sp.Pop.NTZ <- array(0, dim=c(length(shallow_NTZ_ID), MaxAge, MaxYear))

SIM.Sp.F <- list()
SIM.Sp.NTZ <- list()
SIM.N.Dist <- list()
SIM.N.Catches <- list()
SIM.Age.Catches <- list()
SIM.Weight.Catches <- list()

#### RUN MODEL ####
Start=Sys.time()
for (SIM in 1:100){ # Simulation loop
  
  #### SET UP LISTS TO HOLD THE PLOTS ####
  SpatialPlots <- list()
  LengthPlots <- list()
  AgePlots <- list()
  TimesPlotted = 0
  
  #### SET UP INITIAL POPULATION ####
  PopTotal <- array(0, dim=c(MaxCell, 12, MaxYear)) # This is our total population, all ages are summed and each column is a month (each layer is a year)
  Total <- array(NA, dim=c(MaxYear,1)) # For plotting
  
  print(paste0("SIM", sep=" ", SIM))
  
  setwd(sg_dir)
  YearlyTotal <- readRDS(paste0(model.name, sep="_", "BurnInPop_High_M"))
  
  for (YEAR in 25:(MaxYear-1)){ # Start of model year loop
    
    print(YEAR)
    
    ## Loop over all the Rcpp functions in the model
    ModelOutput <- RunModelfunc_cpp(YEAR, MaxAge, MaxYear, MaxCell, NatMort, BHa, BHb, PF, AdultMove, Mature, Weight, Settlement, 
                                    YearlyTotal, Selectivity, Effort)
    
    ## Get outputs from the model
    # Have to add 1 to all YEAR because the loop is now starting at 0
    ## Abundance in different areas
    
    PopTotal[ , ,YEAR+1] <- rowSums(ModelOutput$YearlyTotal[,,1:30], dim=2) # This flattens the matrix to give you the number of fish present in the population each month in each cell, with layers representing the year
    
    # Whole area
    Water$pop <- PopTotal[ , 12, YEAR+1] # We just want the population at the end of the year
    Total[YEAR+1,1] <- sum(Water$pop) # Add this to a dataframe we can then use later 
    
    # By zone
    Sp.Pop.F[,,YEAR+1] <- ModelOutput$YearlyTotal[c(shallow_F_ID),12, ] # Saving the population at the end of the year in cells <30m depth for plots
    Sp.Pop.NTZ[,,YEAR+1] <- ModelOutput$YearlyTotal[c(shallow_NTZ_ID),12, ] # Saving the population at the end of the year in cells <30m depth for plots
    
    # By cell so we can get distances to boat ramps
    Pop.Total.Dist[ ,YEAR+1] <- PopTotal[,12,YEAR+1]
    
    ## Catch data
    monthly.catch <- ModelOutput$month_catch
    age.catch[,,YEAR+1] <- colSums(ModelOutput$month_catch) #This is the number of fish in each age class caught in each month
    
    catch.by.cell[,YEAR+1] <- rowSums(monthly.catch[,,3:30], dims=1) # Number of legal size fish caught in each cell 
    catch.by.age[,YEAR+1] <- colSums(age.catch[,,YEAR+1]) # number of fish caught at by the end of the year in each age class
    
    monthly.catch.weight <- ModelOutput$month_catch_weight
    catch.by.weight[ ,YEAR+1] <- rowSums(monthly.catch.weight[,,3:30], dims=1)
    
    # if(YEAR==58){ # Have to subtract one because the loop now starts at 0
    #   TotalPop <- as.data.frame(Total) %>%
    #     rename(Tot.Pop="V1")
    #   TotalPop$Year <- seq(1987, 2018, by=1)
    #   TotalPlot <- total.plot.func(pop=TotalPop)
    # #   print(TotalPlot)
    # } else { }
    # 
    # if(YEAR %%5==0|YEAR==58){
    #   TimesPlotted <- TimesPlotted+1
    #   #SpatialPlots[[TimesPlotted]] <- spatial.plot.func(area=Water, pop=Total, pop.breaks=pop.groups, colours="PuBu")
    #   #AgePlots[[TimesPlotted]] <- age.plot.func(pop=YearlyTotal, NTZs=NoTake)
    #   
    # } else { }
    
    Sim.Pop[YEAR+1, SIM] <- Total[YEAR+1,1] 
    Sim.Ages[ ,YEAR+1,SIM] <- colSums(ModelOutput$YearlyTotal[,12,1:30]) #Number of fish present in age age group at the end of the year
  } # End of model year loop
  
  ## Population in different zones
  SIM.Sp.F[[SIM]] <- Sp.Pop.F
  SIM.Sp.NTZ[[SIM]] <- Sp.Pop.NTZ
  SIM.N.Dist[[SIM]] <- Pop.Total.Dist
  
  ## Catches
  SIM.N.Catches[[SIM]] <- catch.by.cell # Catches in each cell
  SIM.Age.Catches[[SIM]] <- catch.by.age # Catches by age in each month of the year in each year
  SIM.Weight.Catches[[SIM]] <- catch.by.weight
  if(SIM==200){ # Saving if statement
    setwd(pop_dir)
    print(Movement_Speed)
    print(Scenario)
    
    ## Population
    # Total population
    filename <- paste0(model.name, sep="_", "Total_Population", sep="_", Scenario, sep="_", Movement_Speed)
    saveRDS(Sim.Pop, file=filename)
    
    # Numbers of each age that make it to the end of each year
    filename <- paste0(model.name, sep="_", "Age_Distribution", sep="_", Scenario, sep="_", Movement_Speed)
    saveRDS(Sim.Ages, file=filename)
    
    # Numbers of fish of each age, inside and outside sanctuary zones
    filename <- paste0(model.name, sep="_", "Sp_Population_NTZ", sep="_", Scenario, sep="_", Movement_Speed)
    saveRDS(SIM.Sp.NTZ, file=filename)

    filename <- paste0(model.name, sep="_", "Sp_Population_F", sep="_", Scenario, sep="_", Movement_Speed)
    saveRDS(SIM.Sp.F, file=filename)
    
    # Number of fish in each cell at the end of each year
    filename <- paste0(model.name, sep="_", "Cell_Population", sep="_", Scenario, sep="_", Movement_Speed)
    saveRDS(SIM.N.Dist, file=filename)
    
    ## Catches
    # Catch in each year by age
    filename <- paste0(model.name, sep="_", "Catch_by_Age_Baranov", sep="_", Scenario, sep="_", Movement_Speed)
    saveRDS(SIM.Age.Catches, file=filename)
  
    # catch in each cell across the year
    filename <- paste0(model.name, sep="_", "Catch_by_Cell_Baranov", sep="_", Scenario, sep="_", Movement_Speed)
    saveRDS(SIM.N.Catches, file=filename)
    
    # Catch in each cell by weight across the year
    filename <- paste0(model.name, sep="_", "Catch_by_Weight", sep="_", Scenario, sep="_", Movement_Speed)
    saveRDS(SIM.Weight.Catches, file=filename)
    
  } else { }# End saving if statement

} # End simulation loop
End = Sys.time() 
Runtime = End - Start
Runtime

# finished_email <- gm_mime() %>%
#   gm_to("charlotte.aston@research.uwa.edu.au") %>%
#   gm_from("charlotte.aston@marineecology.io") %>%
#   gm_subject("Code has finished running on my computer") %>%
#   gm_text_body("It's done, Yew!")
# 
# d <- gm_create_draft(finished_email)
# gm_send_draft(d)

# 
setwd(sg_dir)
unfished.bio <- readRDS(paste0(model.name, sep="_", "BurnInPop"))

temp <- unfished.bio[,12,]
temp2 <- colSums(temp)
temp3 <- temp2 * Mature[,12]
Unf.Mat.Bio <- sum(temp3 * Weight[,12])


fished.Bio <- total_pop_list[[1]]

fished.bio <- total_pop_list[[1]][,,1]
temp <- fished.bio[,48]
# temp2 <- colSums(temp)
temp3 <- temp * Mature[,12]
Mat.Bio <- sum(temp3 * Weight[,12])


Mat.Bio/Unf.Mat.Bio
sum(SIM.N.Catches[[1]][,59])
