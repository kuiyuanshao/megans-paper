lapply(c("dplyr", "stringr", "torch"), require, character.only = T)
lapply(paste0("./megans/", list.files("./megans")), source)
source("00_utils_functions.R")

if(!dir.exists('./simulations')){dir.create('./simulations')}
if(!dir.exists('./simulations/SRS')){dir.create('./simulations/SRS')}
if(!dir.exists('./simulations/Balance')){dir.create('./simulations/Balance')}
if(!dir.exists('./simulations/Neyman')){dir.create('./simulations/Neyman')}

if(!dir.exists('./simulations/SRS/megans')){dir.create('./simulations/SRS/megans')}
if(!dir.exists('./simulations/Balance/megans')){dir.create('./simulations/Balance/megans')}
if(!dir.exists('./simulations/Neyman/megans')){dir.create('./simulations/Neyman/megans')}

args <- commandArgs(trailingOnly = TRUE)
task_id <- as.integer(ifelse(length(args) >= 1,
                             args[1],
                             Sys.getenv("SLURM_ARRAY_TASK_ID", "1")))

replicate <- 500
n_chunks <- 20
chunk_size <- ceiling(replicate / n_chunks)
first_rep <- (task_id - 1) * chunk_size + 1
last_rep <- min(task_id * chunk_size, replicate)

for (i in first_rep:last_rep){
  digit <- stringr::str_pad(i, 4, pad = 0)
  cat("Current:", digit, "\n")
  load(paste0("./data/Complete/", digit, ".RData"))
  samp_srs <- read.csv(paste0("./data/Sample/SRS/", digit, ".csv"))
  samp_balance <- read.csv(paste0("./data/Sample/Balance/", digit, ".csv"))
  samp_neyman <- read.csv(paste0("./data/Sample/Neyman/", digit, ".csv"))
  
  samp_srs <- match_types(samp_srs, data) %>% 
    mutate(across(all_of(data_info_srs$cat_vars), as.factor, .names = "{.col}"),
           across(all_of(data_info_srs$num_vars), as.numeric, .names = "{.col}"))
  samp_balance <- match_types(samp_balance, data) %>% 
    mutate(across(all_of(data_info_balance$cat_vars), as.factor, .names = "{.col}"),
           across(all_of(data_info_balance$num_vars), as.numeric, .names = "{.col}"))
  samp_neyman <- match_types(samp_neyman, data) %>% 
    mutate(across(all_of(data_info_neyman$cat_vars), as.factor, .names = "{.col}"),
           across(all_of(data_info_neyman$num_vars), as.numeric, .names = "{.col}"))
  
  # MEGANs:
  # if (!file.exists(paste0("./simulations/SRS/megans/", digit, ".RData"))){
  #   megans_imp <- mmer.impute.cwgangp(samp_srs, m = 20, 
  #                                     num.normalizing = "mode", 
  #                                     cat.encoding = "onehot", 
  #                                     device = "cpu", epochs = 5000,
  #                                     params = list(lambda = 50), 
  #                                     data_info = data_info_srs, save.step = 20000)
  #   save(megans_imp, file = paste0("./simulations/SRS/megans/", digit, ".RData"))
  # }
  # if (!file.exists(paste0("./simulations/Neyman/megans/", digit, ".RData"))){
    megans_imp <- mmer.impute.cwgangp(samp_balance, m = 5, 
                                      num.normalizing = "mode", 
                                      cat.encoding = "onehot", 
                                      device = "cpu", epochs = 5000,
                                      params = list(lambda = 50), 
                                      data_info = data_info_balance, save.step = 20000)
    save(megans_imp, file = paste0("./simulations/Balance/megans/", digit, ".RData"))
  # }
  # if (!file.exists(paste0("./simulations/Neyman/megans/", digit, ".RData"))){
  #   megans_imp <- mmer.impute.cwgangp(samp_neyman, m = 20, 
  #                                     num.normalizing = "mode", 
  #                                     cat.encoding = "onehot", 
  #                                     device = "cpu", epochs = 5000, 
  #                                     params = list(lambda = 50),
  #                                     data_info = data_info_neyman, save.step = 20000)
  #   save(megans_imp, file = paste0("./simulations/Neyman/megans/", digit, ".RData"))
  # }
}

load(paste0("./data/Complete/", digit, ".RData"))

cox.true <- coxph(Surv(T_I, EVENT) ~ I((HbA1c - 50) / 5) + 
                    rs4506565 + I((AGE - 50) / 5) + SEX + INSURANCE + 
                    RACE + I(BMI / 5) + SMOKE, data = data)
megans_imp$imputation <- lapply(megans_imp$imputation, function(dat){
  match_types(dat, data)
})
imp.mids <- as.mids(megans_imp$imputation)
fit <- with(data = imp.mids, 
            exp = coxph(Surv(T_I, EVENT) ~ I((HbA1c - 50) / 5) + 
                          rs4506565 + I((AGE - 50) / 5) + 
                          SEX + INSURANCE + 
                          RACE + I(BMI / 5) + SMOKE))
pooled <- mice::pool(fit)
sumry <- summary(pooled, conf.int = TRUE)
exp(sumry$estimate) - exp(coef(cox.true))

gsamples <- megans_imp$gsample[[1]]
vars_to_pmm <- "T_I"
if (!is.null(vars_to_pmm)){
  for (i in vars_to_pmm){
    
      pmm_matched <- pmm(gsamples[samp_balance$R == 1, i],
                         gsamples[samp_balance$R == 0, i],
                         samp_balance[samp_balance$R == 1, i], 5)
      gsamples[samp_balance$R == 0, i] <- pmm_matched
    
  }
}

ggplot(megans_imp$imputation[[1]]) + 
  geom_density(aes(x = T_I), colour = "red") +
  geom_density(aes(x = T_I), data = data)

ggplot(megans_imp$imputation[[1]]) + 
  geom_density(aes(x = HbA1c), colour = "red") +
  geom_density(aes(x = HbA1c), data = data)

ggplot() + 
  geom_density(aes(x = T_I_STAR - T_I), data = data)

curr_col_obs <- data$T_I_STAR - data$T_I
mc <- mclust::Mclust(curr_col_obs, G = 1:9, verbose = F)
pred <- predict(mc, newdata = curr_col_obs)
mode_labels <- as.numeric(as.factor(pred$classification))
mode_means <- mc$parameters$mean + 1e-6
mode_sds <- sqrt(mc$parameters$variance$sigmasq) + 1e-6
# mode_means <- c()
# mode_sds <- c()
curr_col_norm <- rep(NA, length(curr_col_obs))
for (mode in sort(unique(mode_labels))) {
  mode <- as.numeric(mode)
  idx <- which(mode_labels == mode)
  #mode_means <- c(mode_means, mean(curr_col_obs[idx]))
  #mode_sds <- c(mode_sds, sd(curr_col_obs[idx]))
  if (is.na(mode_sds[mode]) | mode_sds[mode] == 0){
    curr_col_norm[idx] <- (curr_col_obs[idx] - mode_means[mode])
  }else{
    curr_col_norm[idx] <- (curr_col_obs[idx] - mode_means[mode]) / (mode_sds[mode])
  }
}

ggplot() + 
  geom_density(aes(x = acc_prob(as.matrix(data %>% select(c("T_I", "HbA1c")) - 10), lb, ub)), data = data)
