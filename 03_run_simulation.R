lapply(c("mice", "mixgb", "dplyr", "stringr"), require, character.only = T)
lapply(paste0("./megans/", list.files("./megans")), source)
lapply(paste0("./comparisons/gain/", list.files("./comparisons/gain/")), source)
lapply(paste0("./comparisons/mice/", list.files("./comparisons/mice/")), source)
lapply(paste0("./comparisons/mixgb/", list.files("./comparisons/mixgb/")), source)
lapply(paste0("./comparisons/raking/", list.files("./comparisons/raking/")), source)

if(!dir.exists('./simulations')){system('mkdir ./simulations')}
if(!dir.exists('./simulations/Balance')){system('mkdir ./simulations/Balance')}
if(!dir.exists('./simulations/Neyman')){system('mkdir ./simulations/Neyman')}

if(!dir.exists('./simulations/Balance/megans')){system('mkdir ./simulations/Balance/megans')}
if(!dir.exists('./simulations/Neyman/megans')){system('mkdir ./simulations/Neyman/megans')}

if(!dir.exists('./simulations/Balance/gain')){system('mkdir ./simulations/Balance/gain')}
if(!dir.exists('./simulations/Neyman/gain')){system('mkdir ./simulations/Neyman/gain')}

if(!dir.exists('./simulations/Balance/mice')){system('mkdir ./simulations/Balance/mice')}
if(!dir.exists('./simulations/Neyman/mice')){system('mkdir ./simulations/Neyman/mice')}

if(!dir.exists('./simulations/Balance/mixgb')){system('mkdir ./simulations/Balance/mixgb')}
if(!dir.exists('./simulations/Neyman/mixgb')){system('mkdir ./simulations/Neyman/mixgb')}

if(!dir.exists('./simulations/Balance/raking')){system('mkdir ./simulations/Balance/raking')}
if(!dir.exists('./simulations/Neyman/raking')){system('mkdir ./simulations/Neyman/raking')}

data_info <- list(weight_var = "W",
                  cat_vars = c("SEX", "RACE", "SMOKE", "EXER", "ALC", "INSURANCE", "REGION", 
                               "URBAN", "INCOME", "MARRIAGE", 
                               "rs10811661", "rs7756992", "rs11708067", "rs17036101", "rs17584499",
                               "rs1111875", "rs4402960", "rs4607103", "rs7754840", "rs9300039",
                               "rs5015480", "rs9465871", "rs4506565", "rs5219", "rs358806", 
                               "HYPERTENSION", 
                               "SMOKE_STAR", "ALC_STAR", "EXER_STAR", "INCOME_STAR",
                               "rs10811661_STAR", "rs7756992_STAR", "rs11708067_STAR", "rs17036101_STAR", "rs17584499_STAR",
                               "rs1111875_STAR", "rs4402960_STAR", "rs4607103_STAR", "rs7754840_STAR", "rs9300039_STAR",
                               "rs5015480_STAR", "rs9465871_STAR", "rs4506565_STAR", "rs5219_STAR", "rs358806_STAR",
                               "EVENT", "EVENT_STAR", "stratum", "R", "W"),
                  num_vars = c("X", "ID", "AGE", "EDU", "HEIGHT", "BMI", "WEIGHT", "CREATININE",
                               "BUN", "URIC_ACID", "HDL", "LDL", "TG", "WBC",
                               "RBC", "Hb", "HCT", "PLATELET", "PT", "Na_INTAKE",          
                               "K_INTAKE", "KCAL_INTAKE", "PROTEIN_INTAKE", "ALT", "AST", "ALP",                
                               "GGT", "BILIRUBIN", "GLUCOSE", "F_GLUCOSE", "HbA1c", "INSULIN",            
                               "ALBUMIN", "GLOBULIN", "FERRITIN", "CRP", "SBP", "DBP",                
                               "PULSE", "PP", "EDU_STAR", "Na_INTAKE_STAR", "K_INTAKE_STAR", "KCAL_INTAKE_STAR",    
                               "PROTEIN_INTAKE_STAR", "GLUCOSE_STAR", "F_GLUCOSE_STAR", "HbA1c_STAR", "INSULIN_STAR", "T_I",                
                               "T_I_STAR"))
replicate <- 1000
for (i in 1:replicate){
  digit <- stringr::str_pad(i, 4, pad = 0)
  cat("Current:", digit, "\n")
  samp_balance <- read.csv(paste0("./data/Sample/Balance/", digit, ".csv"))
  samp_neyman <- read.csv(paste0("./data/Sample/Neyman/", digit, ".csv"))
  
  samp_balance <- samp_balance %>% 
    mutate(across(all_of(data_info$cat_vars), as.factor, .names = "{.col}"))
  samp_neyman <- samp_neyman %>% 
    mutate(across(all_of(data_info$cat_vars), as.factor, .names = "{.col}"))
  
  # MEGANs:
  megans_imp.balance <- mmer.impute.cwgangp(samp_balance, m = 1, num.normalizing = "mode", cat.encoding = "onehot", 
                                            device = "cuda", epochs = 20000, 
                                            params = list(n_g_layers = 5, n_d_layers = 3,
                                                          beta = 0, 
                                                          type_g = "mlp", type_d = "mlp"), 
                                            data_info = data_info, save.step = 1000)
  save(megans_imp.balance, file = paste0("./simulations/Balance/megans/", digit, ".RData"))
  megans_imp.neyman <- mmer.impute.cwgangp(samp_neyman, m = 20, num.normalizing = "mode", cat.encoding = "onehot", 
                                           device = "cpu", epochs = 10000, 
                                           params = list(n_g_layers = 3, n_d_layers = 2, 
                                                         type_g = "mlp", type_d = "mlp"), 
                                           data_info = data_info, save.step = 1000)
  save(megans_imp.neyman, file = paste0("./simulations/Neyman/megans/", digit, ".RData"))
  
  # GAIN:
  gain_imp.balance <- gain(samp_balance, device = "cpu", batch_size = 128, hint_rate = 0.9, 
                           alpha = 10, beta = 1, n = 10000)
  
  gain_imp.neyman <- gain(samp_neyman, device = "cpu", batch_size = 128, hint_rate = 0.9, 
                          alpha = 10, beta = 1, n = 10000)
  # MICE:
  
}
library(survival)
mod.imp <- coxph(Surv(T_I, EVENT) ~ I(HbA1c / 10) + rs4506565 + I((AGE - 60) / 5) + SEX + INSURANCE + 
        RACE + ALC + SMOKE + EXER, 
        data = match_types(megans_imp.balance$imputation[[1]], data))
load("./data/TRUE/0001.RData")
mod.true <- coxph(Surv(T_I, EVENT) ~ I(HbA1c / 10) + rs4506565 + I((AGE - 60) / 5) + SEX + INSURANCE + 
               RACE + ALC + SMOKE + EXER, data = data)

mod1 <- coxph(Surv(T_I, EVENT) ~ I((HbA1c - 50) / 5) + rs4506565 + I((AGE - 50) / 5) + SEX + INSURANCE + 
        RACE + ALC + SMOKE + EXER, data = data)

mod2 <- coxph(Surv(T_I_STAR, EVENT_STAR) ~ I((HbA1c - 50) / 5) + rs4506565 + I((AGE - 50) / 5) + SEX + INSURANCE + 
                RACE + ALC + SMOKE + EXER, data = data)
ggplot() + 
  geom_density(aes(x = HbA1c), data = megans_imp.balance$imputation[[1]]) + 
  geom_density(aes(x = HbA1c), data = samp_balance, colour = "red") + 
  geom_density(aes(x = HbA1c), data = data, colour = "blue") + 
  geom_density(aes(x = HbA1c_STAR), data = megans_imp.balance$imputation[[1]])

exp(coef(mod1)) - exp(coef(mod2))

m <- Mclust(samp_balance$HbA1c[samp_balance$R == 1])
pred <- predict(m, newdata = samp_balance$HbA1c[samp_balance$R == 1])

match_types <- function(new_df, orig_df) {
  common <- intersect(names(orig_df), names(new_df))
  out <- new_df
  
  for (nm in common) {
    tmpl <- orig_df[[nm]]
    col <- out[[nm]]
    if (is.integer(tmpl))        out[[nm]] <- as.integer(col)
    else if (is.numeric(tmpl))   out[[nm]] <- as.numeric(col)
    else if (is.logical(tmpl))   out[[nm]] <- as.logical(col)
    else if (is.factor(tmpl)) {
      out[[nm]] <- factor(col,
                          levels = levels(tmpl),
                          ordered = is.ordered(tmpl))
    }
    else if (inherits(tmpl, "Date")) {
      out[[nm]] <- as.Date(col)
    } else if (inherits(tmpl, "POSIXct")) {
      tz <- attr(tmpl, "tzone")
      out[[nm]] <- as.POSIXct(col, tz = tz)
    }
    else {
      out[[nm]] <- as.character(col)
    }
  }
  out
}
